import AppKit
import Foundation
import XCTest
@testable import CodexWeeklyReset

final class ServiceReliabilityTests: XCTestCase {
  @MainActor
  func testSleepingDiscoveryTimesOutWithoutBlockingMainActor() async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let discovery = Task {
      await CodexExecutableResolver.commandOutput(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exec /bin/sleep 5"],
        timeout: 0.3
      )
    }
    try await Task.sleep(nanoseconds: 40_000_000)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.25)
    let result = await discovery.value
    XCTAssertNil(result)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
  }

  func testDiscoveryDrainsNoisyStderrWhileCollectingStdout() async {
    let result = await CodexExecutableResolver.commandOutput(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "i=0; while [ $i -lt 2000 ]; do printf '%0500d' 0 >&2; i=$((i + 1)); done; printf '/expected/codex\\n'"],
      timeout: 2
    )
    XCTAssertEqual(result, "/expected/codex")
  }

  func testDiscoveryBoundsNoisyStdoutAndClosedPipes() async {
    let noisy = await CodexExecutableResolver.commandOutput(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "i=0; while [ $i -lt 2000 ]; do printf '%0500d' 0; i=$((i + 1)); done"],
      timeout: 2
    )
    XCTAssertNil(noisy)
    let closed = await CodexExecutableResolver.commandOutput(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exec 1>&- 2>&-; exec /bin/sleep 5"],
      timeout: 0.1
    )
    XCTAssertNil(closed)
  }

  func testSparseUpdateDecodesNullableAndMissingWindowMetadata() throws {
    let json = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":null,"primary":{"usedPercent":40,"resetsAt":null,"windowDurationMins":null}}}}"#
    let notification = try JSONDecoder().decode(RateLimitUpdateNotification.self, from: Data(json.utf8))
    XCTAssertNil(notification.params.rateLimits.limitId)
  }

  @MainActor
  func testStartupRetriesOneTransientAppServerReadFailureWithoutLeavingLoadingState() async throws {
    let (executable, attemptsFile) = try temporaryAppServer(failuresBeforeSuccess: 1)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let monitor = LimitMonitor(
      configuration: AppConfiguration(configuredCodexPath: executable.path, fixturePath: nil,
        notificationOverride: .authorized, pollInterval: 300, disableCodexFallbacks: true),
      resolver: CodexExecutableResolver(configuredPath: executable.path, includeFallbacks: false),
      notifier: FixedNotificationService(state: .authorized),
      appServerRequestTimeout: 0.5,
      startupRetryDelayNanoseconds: 500_000_000
    )

    monitor.start()
    try await waitUntil { self.attemptCount(at: attemptsFile) == 1 }
    try await Task.sleep(nanoseconds: 650_000_000)
    XCTAssertEqual(monitor.state, .loading)
    XCTAssertNil(monitor.lastError)

    monitor.refreshNow()
    try await waitUntil { monitor.state.snapshot != nil }
    XCTAssertEqual(attemptCount(at: attemptsFile), 2, "Manual refresh must not create a third in-flight read")
    XCTAssertEqual(monitor.state.snapshot?.remainingPercent, 40)
    XCTAssertNil(monitor.lastError)
  }

  @MainActor
  func testStartupStopsAfterOneTransientAppServerRetry() async throws {
    let (executable, attemptsFile) = try temporaryAppServer(failuresBeforeSuccess: 2)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let monitor = LimitMonitor(
      configuration: AppConfiguration(configuredCodexPath: executable.path, fixturePath: nil,
        notificationOverride: .authorized, pollInterval: 300, disableCodexFallbacks: true),
      resolver: CodexExecutableResolver(configuredPath: executable.path, includeFallbacks: false),
      notifier: FixedNotificationService(state: .authorized),
      appServerRequestTimeout: 0.5,
      startupRetryDelayNanoseconds: 500_000_000
    )

    monitor.start()
    try await waitUntil {
      if case .failed = monitor.state { return true }
      return false
    }
    XCTAssertEqual(attemptCount(at: attemptsFile), 2)
    XCTAssertNotNil(monitor.lastError)
  }

  @MainActor
  func testStartupDoesNotRetryExecutableDiscoveryFailure() async throws {
    let counter = DiscoveryCounter()
    let monitor = LimitMonitor(
      configuration: AppConfiguration(configuredCodexPath: nil, fixturePath: nil,
        notificationOverride: .authorized, pollInterval: 300, disableCodexFallbacks: true),
      resolver: CodexExecutableResolver(
        commandPathProvider: {
          await counter.begin()
          return nil
        },
        fileIsExecutable: { _ in false }, launchServicesAppURLProvider: { nil }
      ),
      notifier: FixedNotificationService(state: .authorized)
    )

    monitor.start()
    try await waitUntil {
      if case .failed = monitor.state { return true }
      return false
    }
    try await Task.sleep(nanoseconds: 400_000_000)
    let count = await counter.count
    XCTAssertEqual(count, 1)
  }

  @MainActor
  func testStartupDoesNotRetryInvalidFixture() async throws {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixture) }
    try Data("{}".utf8).write(to: fixture)
    let counter = DiscoveryCounter()
    let monitor = LimitMonitor(
      configuration: AppConfiguration(configuredCodexPath: nil, fixturePath: fixture.path,
        notificationOverride: .authorized, pollInterval: 300, disableCodexFallbacks: true),
      resolver: CodexExecutableResolver(
        commandPathProvider: {
          await counter.begin()
          return nil
        },
        fileIsExecutable: { _ in false }, launchServicesAppURLProvider: { nil }
      ),
      notifier: FixedNotificationService(state: .authorized)
    )

    monitor.start()
    try await waitUntil {
      if case .failed = monitor.state { return true }
      return false
    }
    try await Task.sleep(nanoseconds: 400_000_000)
    let count = await counter.count
    XCTAssertEqual(count, 0, "Fixture parse failures must not enter live app-server recovery")
  }

  @MainActor
  func testIdleAndLoadingMenuBarPresentationsStayNeutral() throws {
    _ = NSApplication.shared
    for state in [MonitorState.idle, .loading] {
      let presentation = MenuBarLimitPresentation(state: state)
      XCTAssertEqual(presentation.band, .unknown)
      XCTAssertEqual(presentation.accessibilityValue, "Checking")

      let image = MenuBarLimitGlyphImage.image(for: presentation)
      XCTAssertTrue(image.isTemplate)
      let data = try XCTUnwrap(image.tiffRepresentation)
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
      var redPixels = 0
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
          guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
          if color.alphaComponent > 0.1,
             color.redComponent > color.greenComponent + 0.2,
             color.redComponent > color.blueComponent + 0.2 {
            redPixels += 1
          }
        }
      }
      XCTAssertEqual(redPixels, 0)
    }
  }

  @MainActor
  func testSameSparseUpdateRetriesFailedReadAndClearsError() async throws {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixture) }
    try Data("{}".utf8).write(to: fixture)
    let monitor = LimitMonitor(
      configuration: AppConfiguration(configuredCodexPath: nil, fixturePath: fixture.path,
        notificationOverride: .authorized, pollInterval: 300, disableCodexFallbacks: true),
      resolver: CodexExecutableResolver(includeFallbacks: false),
      notifier: FixedNotificationService(state: .authorized)
    )
    let update = RateLimitUpdate(limitId: nil)
    await monitor.handleRateLimitUpdate(update)
    XCTAssertNotNil(monitor.lastError)
    let json = #"{"rateLimits":{"limitId":"codex","secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":2000000000}}}"#
    try Data(json.utf8).write(to: fixture)
    await monitor.handleRateLimitUpdate(update)
    XCTAssertEqual(monitor.state.snapshot?.remainingPercent, 60)
    XCTAssertNil(monitor.lastError)

    try Data("{}".utf8).write(to: fixture)
    await monitor.handleRateLimitUpdate(RateLimitUpdate(limitId: "codex_spark"))
    XCTAssertNil(monitor.lastError)
    XCTAssertEqual(monitor.state.snapshot?.remainingPercent, 60)
    await monitor.handleRateLimitUpdate(RateLimitUpdate(limitId: "codex"))
    XCTAssertNotNil(monitor.lastError, "A main-bucket read with no quota must still fail visibly")
  }

  @MainActor
  func testUpdatesDuringReadCoalesceIntoOneBoundedFollowup() async throws {
    let counter = DiscoveryCounter()
    let monitor = LimitMonitor(
      configuration: AppConfiguration(configuredCodexPath: nil, fixturePath: nil,
        notificationOverride: .authorized, pollInterval: 300, disableCodexFallbacks: false),
      resolver: CodexExecutableResolver(
        commandPathProvider: {
          await counter.begin()
          try? await Task.sleep(nanoseconds: 120_000_000)
          return nil
        },
        fileIsExecutable: { _ in false }, launchServicesAppURLProvider: { nil }
      ),
      notifier: FixedNotificationService(state: .authorized)
    )
    let initialRead = Task { await monitor.handleRateLimitUpdate(RateLimitUpdate(limitId: "codex")) }
    try await waitUntil { await counter.count == 1 }
    for _ in 0..<5 { await monitor.handleRateLimitUpdate(RateLimitUpdate(limitId: nil)) }
    try await waitUntil { await counter.count == 2 }
    for _ in 0..<5 { await monitor.handleRateLimitUpdate(RateLimitUpdate(limitId: "codex")) }
    await initialRead.value
    try await Task.sleep(nanoseconds: 40_000_000)
    let count = await counter.count
    XCTAssertEqual(count, 2, "Read echoes must not produce an unbounded chain")
    await monitor.handleRateLimitUpdate(RateLimitUpdate(limitId: "codex"))
    let laterCount = await counter.count
    XCTAssertEqual(laterCount, 3, "A later identical update must remain actionable")
  }

  private func waitUntil(_ predicate: () async -> Bool) async throws {
    for _ in 0..<300 {
      if await predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for service state")
  }

  private func temporaryAppServer(failuresBeforeSuccess: Int) throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let attemptsFile = directory.appendingPathComponent("attempts")
    let executable = directory.appendingPathComponent("fake-app-server")
    let script = """
    #!/usr/bin/env python3
    import json
    import pathlib
    import sys
    import time

    attempts_file = pathlib.Path("\(attemptsFile.path)")
    attempt = int(attempts_file.read_text()) + 1 if attempts_file.exists() else 1
    attempts_file.write_text(str(attempt))

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
            print(json.dumps({"id": message["id"], "result": {}}), flush=True)
        elif method == "account/rateLimits/read":
            if attempt <= \(failuresBeforeSuccess):
                time.sleep(30)
            print(json.dumps({
                "id": message["id"],
                "result": {
                    "rateLimitsByLimitId": {
                        "codex": {
                            "limitId": "codex",
                            "secondary": {
                                "usedPercent": 60,
                                "windowDurationMins": 10080,
                                "resetsAt": 2000000000
                            }
                        }
                    }
                }
            }), flush=True)
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return (executable, attemptsFile)
  }

  private func attemptCount(at file: URL) -> Int {
    guard let contents = try? String(contentsOf: file) else { return 0 }
    return Int(contents) ?? 0
  }
}

private actor DiscoveryCounter {
  private(set) var count = 0
  func begin() { count += 1 }
}
