import AppKit
import Combine
import Foundation
import os

@MainActor
final class LimitMonitor: ObservableObject {
  @Published private(set) var state: MonitorState = .idle
  @Published private(set) var isRefreshing = false
  @Published private(set) var notificationState: NotificationPermissionState = .notDetermined
  @Published private(set) var sourcePath = "Resolving"
  @Published private(set) var lastError: String?

  let buildIdentity: BuildIdentity

  private let configuration: AppConfiguration
  private let resolver: CodexExecutableResolver
  private let notifier: UserNotificationManaging
  private let logger = Logger(subsystem: "com.macintog.codexweeklyreset", category: "LimitMonitor")

  private var client: CodexAppServerClient?
  private var clientPath: String?
  private var previousSnapshot: RateLimitSnapshot?
  private var pollTask: Task<Void, Never>?
  private var hasStarted = false

  init(
    configuration: AppConfiguration,
    resolver: CodexExecutableResolver,
    notifier: UserNotificationManaging,
    buildIdentity: BuildIdentity = .current
  ) {
    self.configuration = configuration
    self.resolver = resolver
    self.notifier = notifier
    self.buildIdentity = buildIdentity
  }

  static func live(configuration: AppConfiguration = .live()) -> LimitMonitor {
    let notifier: UserNotificationManaging
    if let override = configuration.notificationOverride {
      notifier = FixedNotificationService(state: override)
    } else {
      notifier = SystemNotificationService()
    }

    return LimitMonitor(
      configuration: configuration,
      resolver: CodexExecutableResolver(
        configuredPath: configuration.configuredCodexPath,
        includeFallbacks: !configuration.disableCodexFallbacks
      ),
      notifier: notifier
    )
  }

  func start() {
    guard !hasStarted else {
      return
    }
    hasStarted = true

    Task {
      await updateNotificationAuthorization()
    }

    Task {
      await refresh(trigger: .startup)
      startPolling()
    }
  }

  func refreshNow() {
    Task {
      await refresh(trigger: .manual)
    }
  }

  func quit() {
    Task {
      await client?.stop()
      NSApplication.shared.terminate(nil)
    }
  }

  private func startPolling() {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      guard let self else {
        return
      }

      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: UInt64(configuration.pollInterval * 1_000_000_000))
        } catch {
          return
        }
        await self.refresh(trigger: .scheduled)
      }
    }
  }

  private func updateNotificationAuthorization() async {
    notificationState = await notifier.authorizationStatus()
    logger.info("Notification authorization status \(self.notificationState.rawValue, privacy: .public)")
    if notificationState == .notDetermined {
      let previousActivationPolicy = NSApp.activationPolicy()
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)

      notificationState = await notifier.requestAuthorization()

      if previousActivationPolicy != .regular {
        NSApp.setActivationPolicy(previousActivationPolicy)
      }

      logger.info("Notification authorization request completed with \(self.notificationState.rawValue, privacy: .public)")
    }
  }

  private func refresh(trigger: RefreshTrigger) async {
    guard !isRefreshing else {
      return
    }

    isRefreshing = true
    if state == .idle || state == .failed("") {
      state = .loading
    }

    defer {
      isRefreshing = false
    }

    do {
      let snapshot = try await readSnapshot()
      apply(snapshot)
      lastError = nil
      logger.info("Updated weekly remaining \(snapshot.remainingPercent, privacy: .public)")
    } catch {
      let message = error.localizedDescription
      lastError = message
      logger.error("Refresh failed: \(message, privacy: .public)")
      if state.snapshot == nil {
        state = .failed(message)
      }
    }
  }

  private func readSnapshot() async throws -> RateLimitSnapshot {
    if let fixturePath = configuration.fixturePath {
      sourcePath = "Fixture"
      return try FixtureRateLimitSource.snapshot(from: fixturePath)
    }

    guard let executable = resolver.resolve() else {
      sourcePath = "Not found"
      throw MonitorError.codexNotFound
    }

    sourcePath = executable.path

    if client == nil || clientPath != executable.path {
      await client?.stop()

      let newClient = CodexAppServerClient(executablePath: executable.path)
      await newClient.setRateLimitUpdateHandler { [weak self] envelope in
        Task { @MainActor in
          self?.applyUpdatedEnvelope(envelope)
        }
      }
      client = newClient
      clientPath = executable.path
    }

    guard let client else {
      throw MonitorError.clientUnavailable
    }

    do {
      let envelope = try await client.readRateLimits()
      return try RateLimitSnapshot.mainCodexWeekly(
        from: envelope,
        sourcePath: executable.path
      )
    } catch {
      logger.warning("Codex app-server read failed: \(error.localizedDescription, privacy: .public)")
      await client.stop()
      self.client = nil
      self.clientPath = nil
      throw MonitorError.appServerReadFailed(error.localizedDescription)
    }
  }

  private func applyUpdatedEnvelope(_ envelope: RateLimitsEnvelope) {
    do {
      let snapshot = try RateLimitSnapshot.mainCodexWeekly(
        from: envelope,
        sourcePath: sourcePath
      )
      apply(snapshot)
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func apply(_ snapshot: RateLimitSnapshot) {
    let previous = previousSnapshot

    if let previous, let event = LimitNotificationPolicy.event(previous: previous, current: snapshot) {
      Task {
        try? await notifier.notify(event, previous: previous, current: snapshot)
        notificationState = await notifier.authorizationStatus()
      }
    }

    previousSnapshot = snapshot
    state = .ready(snapshot)
  }
}

enum RefreshTrigger {
  case startup
  case manual
  case scheduled
}

enum MonitorError: LocalizedError {
  case codexNotFound
  case clientUnavailable
  case appServerReadFailed(String)

  var errorDescription: String? {
    switch self {
    case .codexNotFound:
      return "Codex was not found. Install Codex.app or add codex to PATH."
    case .clientUnavailable:
      return "Codex app-server client was not ready."
    case let .appServerReadFailed(message):
      return "Codex app-server did not return live limits: \(message)"
    }
  }
}
