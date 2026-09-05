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
  private let appServerRequestTimeout: TimeInterval
  private let startupRetryDelayNanoseconds: UInt64
  private let logger = Logger(subsystem: "com.macintog.codexweeklyreset", category: "LimitMonitor")

  private var client: CodexAppServerClient?
  private var clientPath: String?
  private var previousSnapshot: RateLimitSnapshot?
  private var handledResetExpiryAlerts: Set<ResetCreditExpiryAlert> = []
  private var pollTask: Task<Void, Never>?
  private var notificationAuthorizationTask: Task<Void, Never>?
  private var hasStarted = false
  private var needsUpdateRefresh = false
  private var isUpdateFollowup = false

  init(
    configuration: AppConfiguration,
    resolver: CodexExecutableResolver,
    notifier: UserNotificationManaging,
    buildIdentity: BuildIdentity = .current,
    appServerRequestTimeout: TimeInterval = 8,
    startupRetryDelayNanoseconds: UInt64 = 250_000_000
  ) {
    self.configuration = configuration
    self.resolver = resolver
    self.notifier = notifier
    self.buildIdentity = buildIdentity
    self.appServerRequestTimeout = appServerRequestTimeout
    self.startupRetryDelayNanoseconds = startupRetryDelayNanoseconds
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

    notificationAuthorizationTask = Task { [weak self] in
      await self?.updateNotificationAuthorization()
    }
    Task { [weak self] in
      guard let self else { return }
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

  func shouldShowLastCheck(now: Date = Date()) -> Bool {
    guard let snapshot = state.snapshot else {
      return false
    }

    return now.timeIntervalSince(snapshot.checkedAt) >= configuration.pollInterval * 2
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
      isUpdateFollowup = false
      needsUpdateRefresh = false
    }

    for pass in 0..<2 {
      isUpdateFollowup = pass == 1
      needsUpdateRefresh = false
      do {
        let effectiveTrigger: RefreshTrigger = pass == 0 ? trigger : .update
        let snapshot = try await readSnapshotWithStartupRecovery(trigger: effectiveTrigger)
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
      if !needsUpdateRefresh { break }
    }
  }

  private func readSnapshotWithStartupRecovery(trigger: RefreshTrigger) async throws -> RateLimitSnapshot {
    do {
      return try await readSnapshot()
    } catch let error as MonitorError {
      guard case .startup = trigger,
            case .appServerReadFailed = error else {
        throw error
      }

      logger.info("Retrying startup app-server read after a transient failure")
      try await Task.sleep(nanoseconds: startupRetryDelayNanoseconds)
      return try await readSnapshot()
    }
  }

  private func readSnapshot() async throws -> RateLimitSnapshot {
    if let fixturePath = configuration.fixturePath {
      sourcePath = "Fixture"
      return try FixtureRateLimitSource.snapshot(from: fixturePath)
    }

    guard let executable = await resolver.resolve() else {
      sourcePath = "Not found"
      throw MonitorError.codexNotFound
    }

    sourcePath = executable.path

    if client == nil || clientPath != executable.path {
      await client?.stop()

      let newClient = CodexAppServerClient(
        executablePath: executable.path,
        requestTimeout: appServerRequestTimeout
      )
      await newClient.setRateLimitUpdateHandler { [weak self] update in
        Task { @MainActor in
          await self?.handleRateLimitUpdate(update)
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

  func handleRateLimitUpdate(_ update: RateLimitUpdate) async {
    // The protocol permits an absent ID, but a named different bucket cannot
    // change this utility's main Codex quota.
    guard update.limitId == nil || update.limitId == "codex" else { return }
    // One follow-up catches updates received during a read. The final read
    // coalesces further notifications, including server echoes, so it cannot
    // recursively trigger reads. A later identical notification is still valid.
    if isRefreshing {
      if !isUpdateFollowup { needsUpdateRefresh = true }
      return
    }
    await refresh(trigger: .update)
  }

  private func apply(_ snapshot: RateLimitSnapshot) {
    let previous = previousSnapshot

    if let previous, let event = LimitNotificationPolicy.event(previous: previous, current: snapshot) {
      Task {
        await notificationAuthorizationTask?.value
        try? await notifier.notify(event, previous: previous, current: snapshot)
        notificationState = await notifier.authorizationStatus()
      }
    }

    if let alert = ResetCreditGrantPolicy.alert(previous: previous, current: snapshot) {
      Task {
        await notificationAuthorizationTask?.value
        try? await notifier.notify(alert)
        notificationState = await notifier.authorizationStatus()
      }
    }

    if let alert = ResetCreditExpiryPolicy.alert(
      resetCredits: snapshot.resetCredits,
      now: snapshot.checkedAt
    ), handledResetExpiryAlerts.insert(alert).inserted {
      let availableCount = snapshot.resetCredits?.availableCount ?? 0
      Task {
        await notificationAuthorizationTask?.value
        do {
          try await notifier.notify(alert, availableCount: availableCount)
        } catch {
          handledResetExpiryAlerts.remove(alert)
        }
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
  case update
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
