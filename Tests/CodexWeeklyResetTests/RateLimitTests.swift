import XCTest
@testable import CodexWeeklyReset

final class RateLimitTests: XCTestCase {
  func testParsesMainCodexWeeklyBucket() throws {
    let envelope = try decodeEnvelope("""
    {"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":1777744100},"secondary":{"usedPercent":52,"windowDurationMins":10080,"resetsAt":1777986630},"planType":"pro","rateLimitReachedType":null}}}
    """)

    let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = try RateLimitSnapshot.mainCodexWeekly(
      from: envelope,
      checkedAt: checkedAt,
      sourcePath: "/Applications/Codex.app/Contents/Resources/codex"
    )

    XCTAssertEqual(snapshot.limitId, "codex")
    XCTAssertEqual(snapshot.remainingPercent, 48, accuracy: 0.001)
    XCTAssertEqual(snapshot.usedPercent, 52, accuracy: 0.001)
    XCTAssertEqual(snapshot.windowDurationMins, 10080)
    XCTAssertEqual(snapshot.planType, "pro")
    XCTAssertEqual(snapshot.checkedAt, checkedAt)
  }

  func testPrefersMainCodexOverModelSpecificBucket() throws {
    let envelope = try decodeEnvelope("""
    {"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":10},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":20}},"codex_model":{"limitId":"codex_model","limitName":"Model","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":10},"secondary":{"usedPercent":90,"windowDurationMins":10080,"resetsAt":20}}}}
    """)

    let snapshot = try RateLimitSnapshot.mainCodexWeekly(
      from: envelope,
      sourcePath: "/opt/homebrew/bin/codex"
    )

    XCTAssertEqual(snapshot.limitId, "codex")
    XCTAssertEqual(snapshot.remainingPercent, 80, accuracy: 0.001)
  }

  func testMissingWeeklyWindowThrows() throws {
    let envelope = try decodeEnvelope("""
    {"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":1777744100}}}}
    """)

    XCTAssertThrowsError(try RateLimitSnapshot.mainCodexWeekly(from: envelope, sourcePath: "/x")) { error in
      XCTAssertEqual(error as? RateLimitSelectionError, .missingWeeklyWindow)
    }
  }

  func testNotificationPolicySuppressesFirstReadAndSmallMoves() {
    let previous = snapshot(remaining: 48)

    XCTAssertFalse(LimitNotificationPolicy.shouldNotifyIncrease(previous: nil, current: previous))
    XCTAssertFalse(LimitNotificationPolicy.shouldNotifyIncrease(previous: previous, current: snapshot(remaining: 48.9)))
    XCTAssertFalse(LimitNotificationPolicy.shouldNotifyIncrease(previous: previous, current: snapshot(remaining: 49)))
    XCTAssertTrue(LimitNotificationPolicy.shouldNotifyIncrease(previous: previous, current: snapshot(remaining: 56)))
    XCTAssertTrue(LimitNotificationPolicy.shouldNotifyIncrease(previous: previous, current: snapshot(remaining: 100)))
  }

  func testNotificationPolicyEmitsLowQuotaWhenCrossingTwentyPercent() {
    XCTAssertNil(LimitNotificationPolicy.event(previous: nil, current: snapshot(remaining: 20)))
    XCTAssertNil(LimitNotificationPolicy.event(previous: snapshot(remaining: 20), current: snapshot(remaining: 12)))
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 21), current: snapshot(remaining: 20)),
      .lowQuota
    )
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 45), current: snapshot(remaining: 18)),
      .lowQuota
    )
  }

  func testNotificationPolicyEmitsRedQuotaWhenCrossingBelowTenPercent() {
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 10), current: snapshot(remaining: 9)),
      .redQuota
    )
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 20), current: snapshot(remaining: 5)),
      .redQuota
    )
    XCTAssertNil(LimitNotificationPolicy.event(previous: snapshot(remaining: 9), current: snapshot(remaining: 4)))
  }

  func testNotificationPolicyEmitsQuotaExhaustedWhenCrossingToZero() {
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 9), current: snapshot(remaining: 0)),
      .quotaExhausted
    )
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 50), current: snapshot(remaining: 0)),
      .quotaExhausted
    )
    XCTAssertNil(LimitNotificationPolicy.event(previous: snapshot(remaining: 0), current: snapshot(remaining: 0)))
  }

  func testNotificationPolicyEmitsQuotaIncreasedForResetJump() {
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 0), current: snapshot(remaining: 100)),
      .quotaIncreased
    )
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 18), current: snapshot(remaining: 99)),
      .quotaIncreased
    )
  }

  func testNotificationEventCopyMatchesOSNotificationCases() {
    let previous = snapshot(remaining: 4)
    let current = snapshot(
      remaining: 0,
      checkedAt: Date(timeIntervalSince1970: 1_000),
      resetsAt: Date(timeIntervalSince1970: 184_600)
    )

    XCTAssertEqual(LimitNotificationEvent.lowQuota.title, "Codex weekly quota is low")
    XCTAssertEqual(LimitNotificationEvent.redQuota.title, "Codex weekly quota is low")
    XCTAssertEqual(LimitNotificationEvent.quotaExhausted.title, "Codex weekly limit exhausted")
    XCTAssertEqual(LimitNotificationEvent.quotaIncreased.title, "Codex weekly quota increased")
    XCTAssertEqual(LimitNotificationEvent.lowQuota.body(previous: previous, current: snapshot(remaining: 18)), "Less than 20% remaining.")
    XCTAssertEqual(LimitNotificationEvent.redQuota.body(previous: previous, current: snapshot(remaining: 9)), "Less than 10% remaining.")
    XCTAssertEqual(LimitNotificationEvent.quotaExhausted.body(previous: previous, current: current), "Reset is in 2 days 3 hours.")
  }

  func testMenuBarPresentationBandsRemainingCapacity() {
    XCTAssertEqual(QuotaIndicatorBand(filledSlots: 5), .healthy)
    XCTAssertEqual(QuotaIndicatorBand(filledSlots: 2), .caution)
    XCTAssertEqual(QuotaIndicatorBand(filledSlots: 1), .alarm)
    XCTAssertEqual(QuotaIndicatorBand(filledSlots: 0), .alarm)
  }

  func testNotificationPolicyUsesSameNineSlotThresholdsAsMenuBar() {
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 100), 9)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 89), 9)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 88.8), 8)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 78), 8)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 77.7), 7)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 22.2), 2)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 11.1), 1)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 0), 0)
  }

  func testQuotaIndicatorBandUsesSharedNineSlotThresholds() {
    XCTAssertEqual(QuotaIndicatorSlots.band(forRemainingPercent: 43), .healthy)
    XCTAssertEqual(QuotaIndicatorSlots.band(forRemainingPercent: 22.2), .caution)
    XCTAssertEqual(QuotaIndicatorSlots.band(forRemainingPercent: 11.1), .alarm)
    XCTAssertEqual(QuotaIndicatorSlots.band(forRemainingPercent: 0), .alarm)
  }

  func testMenuBarPresentationUsesApproximateGlyphStateWithoutDisplayText() {
    let presentation = MenuBarLimitPresentation(state: .ready(snapshot(remaining: 47)))

    XCTAssertEqual(presentation.fraction, 0.47, accuracy: 0.001)
    XCTAssertEqual(presentation.band, .healthy)
    XCTAssertEqual(presentation.filledCells, 5)
    XCTAssertEqual(presentation.accessibilityValue, "47% weekly remaining")
  }

  func testMenuBarGlyphDrainsFromTopLeftTowardBottomRight() {
    XCTAssertFalse(MenuBarLimitGlyphImage.isFilledCell(0, filledCells: 2))
    XCTAssertFalse(MenuBarLimitGlyphImage.isFilledCell(6, filledCells: 2))
    XCTAssertTrue(MenuBarLimitGlyphImage.isFilledCell(7, filledCells: 2))
    XCTAssertTrue(MenuBarLimitGlyphImage.isFilledCell(8, filledCells: 2))
  }

  func testAppServerExitErrorIncludesStderrTail() {
    let error = CodexAppServerError.processExited(64, stderr: "invalid auth token\n")

    XCTAssertEqual(error.localizedDescription, "Codex app-server exited with status 64: invalid auth token")
  }

  func testAppServerClientReadsRateLimitsFromInteractiveServer() async throws {
    let executable = try temporaryExecutable("""
    #!/usr/bin/env python3
    import json
    import sys

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
            print(json.dumps({"id": message["id"], "result": {}}), flush=True)
            print(json.dumps({"method": "remoteControl/status/changed", "params": {"status": "disabled", "environmentId": None}}), flush=True)
        elif method == "account/rateLimits/read":
            print(json.dumps({
                "id": message["id"],
                "result": {
                    "rateLimitsByLimitId": {
                        "codex": {
                            "limitId": "codex",
                            "limitName": None,
                            "primary": {"usedPercent": 8, "windowDurationMins": 300, "resetsAt": 1777762101},
                            "secondary": {"usedPercent": 60, "windowDurationMins": 10080, "resetsAt": 1777986630},
                            "credits": {"hasCredits": False, "unlimited": False, "balance": "0"},
                            "planType": "pro",
                            "rateLimitReachedType": None
                        }
                    }
                }
            }), flush=True)
    """)

    let client = CodexAppServerClient(executablePath: executable.path, requestTimeout: 2)
    let envelope = try await client.readRateLimits()
    let snapshot = try RateLimitSnapshot.mainCodexWeekly(
      from: envelope,
      sourcePath: executable.path
    )
    await client.stop()

    XCTAssertEqual(snapshot.remainingPercent, 40, accuracy: 0.001)
    XCTAssertEqual(snapshot.sourcePath, executable.path)
  }

  func testAppServerClientTimesOutWhenServerDoesNotAnswer() async throws {
    let executable = try temporaryExecutable("""
    #!/usr/bin/env python3
    import time

    time.sleep(30)
    """)

    let client = CodexAppServerClient(executablePath: executable.path, requestTimeout: 0.2)
    defer {
      Task {
        await client.stop()
      }
    }

    do {
      _ = try await client.readRateLimits()
      XCTFail("Expected app-server timeout")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Codex app-server did not respond.")
    }
  }

  func testRealCodexAppServerClientReadsRateLimitsWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["CODEX_WEEKLY_RESET_REAL_APP_SERVER_TEST"] == "1" else {
      throw XCTSkip("Set CODEX_WEEKLY_RESET_REAL_APP_SERVER_TEST=1 to probe the real Codex app-server.")
    }

    let executablePath = ProcessInfo.processInfo.environment["CODEX_WEEKLY_RESET_REAL_CODEX_PATH"]
      ?? "/opt/homebrew/bin/codex"
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw XCTSkip("Codex executable is not available at \(executablePath).")
    }

    let client = CodexAppServerClient(executablePath: executablePath, requestTimeout: 5)
    let envelope = try await client.readRateLimits()
    _ = try RateLimitSnapshot.mainCodexWeekly(
      from: envelope,
      sourcePath: executablePath
    )
    await client.stop()
  }

  func testSourceLabelsCollapseFixturePaths() {
    XCTAssertEqual(
      DisplayFormatters.sourceLabel("Fixture: /tmp/rate-limits.json"),
      "Fixture"
    )
    XCTAssertEqual(
      DisplayFormatters.sourceLabel("/opt/homebrew/bin/codex"),
      "/opt/homebrew/bin/codex"
    )
  }

  func testAppServerEnvironmentStripsAppBundleAndXPCState() {
    let sanitized = CodexAppServerClient.sanitizedEnvironment(
      from: [
        "__CFBundleIdentifier": "com.macintog.codexweeklyreset",
        "XPC_SERVICE_NAME": "application.com.macintog.codexweeklyreset",
        "XPC_FLAGS": "1",
        "HOME": "/Users/tester",
        "PATH": "/opt/homebrew/bin:/usr/bin",
        "SHELL": "/bin/zsh",
        "CODEX_HOME": "/Users/tester/.codex"
      ],
      homeDirectory: "/Users/tester"
    )

    XCTAssertNil(sanitized["__CFBundleIdentifier"])
    XCTAssertNil(sanitized["XPC_SERVICE_NAME"])
    XCTAssertNil(sanitized["XPC_FLAGS"])
    XCTAssertEqual(sanitized["HOME"], "/Users/tester")
    XCTAssertEqual(sanitized["PATH"], "/opt/homebrew/bin:/usr/bin")
    XCTAssertEqual(sanitized["CODEX_HOME"], "/Users/tester/.codex")
  }

  private func decodeEnvelope(_ json: String) throws -> RateLimitsEnvelope {
    try JSONDecoder().decode(RateLimitsEnvelope.self, from: Data(json.utf8))
  }

  private func temporaryExecutable(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    let executable = directory.appendingPathComponent("fake-app-server")
    try contents.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    return executable
  }

  private func snapshot(
    remaining: Double,
    checkedAt: Date = Date(timeIntervalSince1970: 1_000),
    resetsAt: Date = Date(timeIntervalSince1970: 2_000)
  ) -> RateLimitSnapshot {
    RateLimitSnapshot(
      limitId: "codex",
      limitName: nil,
      usedPercent: 100 - remaining,
      remainingPercent: remaining,
      windowDurationMins: 10080,
      resetsAt: resetsAt,
      checkedAt: checkedAt,
      planType: "pro",
      sourcePath: "/codex"
    )
  }
}
