import Foundation
import XCTest
@testable import CodexWeeklyReset

final class ResolverAndFixtureTests: XCTestCase {
  func testResolverUsesConfiguredPathFirst() {
    let resolver = CodexExecutableResolver(
      configuredPath: "~/bin/codex",
      commandPathProvider: { "/opt/homebrew/bin/codex" },
      fileIsExecutable: { $0 == "/Users/test/bin/codex" || $0 == "/opt/homebrew/bin/codex" },
      homeDirectory: URL(fileURLWithPath: "/Users/test"),
      includeFallbacks: true,
      launchServicesAppURLProvider: { nil }
    )

    XCTAssertEqual(
      resolver.resolve(),
      CodexExecutable(path: "/Users/test/bin/codex", source: "Configured")
    )
  }

  func testResolverFallsBackToApplicationsBeforeLaunchServices() {
    let resolver = CodexExecutableResolver(
      configuredPath: nil,
      commandPathProvider: { nil },
      fileIsExecutable: { path in
        path == "/Applications/Codex.app/Contents/Resources/codex"
          || path == "/Resolved/Codex.app/Contents/Resources/codex"
      },
      homeDirectory: URL(fileURLWithPath: "/Users/test"),
      includeFallbacks: true,
      launchServicesAppURLProvider: { URL(fileURLWithPath: "/Resolved/Codex.app") }
    )

    XCTAssertEqual(
      resolver.resolve(),
      CodexExecutable(path: "/Applications/Codex.app/Contents/Resources/codex", source: "/Applications")
    )
  }

  func testAppConfigurationParsesFixtureAndNotificationOverride() {
    let configuration = AppConfiguration.live(
      environment: [
        "CODEX_WEEKLY_RESET_FIXTURE": "/tmp/limits.json",
        "CODEX_WEEKLY_RESET_NOTIFICATION_STATE": "denied",
        "CODEX_WEEKLY_RESET_POLL_INTERVAL": "60"
      ],
      arguments: ["CodexWeeklyReset"]
    )

    XCTAssertEqual(configuration.fixturePath, "/tmp/limits.json")
    XCTAssertEqual(configuration.notificationOverride, .denied)
    XCTAssertEqual(configuration.pollInterval, 60)
    XCTAssertFalse(configuration.disableCodexFallbacks)
  }

  func testResolverCanDisableFallbacksForMissingCodexFixtureState() {
    let resolver = CodexExecutableResolver(
      configuredPath: "/missing/codex",
      commandPathProvider: { "/opt/homebrew/bin/codex" },
      fileIsExecutable: { $0 == "/opt/homebrew/bin/codex" },
      homeDirectory: URL(fileURLWithPath: "/Users/test"),
      includeFallbacks: false,
      launchServicesAppURLProvider: { URL(fileURLWithPath: "/Applications/Codex.app") }
    )

    XCTAssertNil(resolver.resolve())
  }

  func testFixtureSourceReadsRpcResponseShape() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = directory.appendingPathComponent("limits.json")
    try """
    {"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1777744100},"secondary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1777986630},"planType":"pro"}}}}
    """.write(to: fixture, atomically: true, encoding: .utf8)

    let snapshot = try FixtureRateLimitSource.snapshot(from: fixture.path)

    XCTAssertEqual(snapshot.limitId, "codex")
    XCTAssertEqual(snapshot.remainingPercent, 59, accuracy: 0.001)
    XCTAssertTrue(snapshot.sourcePath.hasPrefix("Fixture:"))
  }
}
