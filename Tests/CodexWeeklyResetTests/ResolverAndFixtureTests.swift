import Foundation
import XCTest
@testable import CodexWeeklyReset

final class ResolverAndFixtureTests: XCTestCase {
  func testResolverUsesConfiguredPathFirst() async {
    let resolver = CodexExecutableResolver(
      configuredPath: "~/bin/codex",
      commandPathProvider: { "/opt/homebrew/bin/codex" },
      fileIsExecutable: { $0 == "/Users/test/bin/codex" || $0 == "/opt/homebrew/bin/codex" },
      homeDirectory: URL(fileURLWithPath: "/Users/test"),
      includeFallbacks: true,
      launchServicesAppURLProvider: { _ in nil },
      runningApplicationURLsProvider: { [] }
    )

    let result = await resolver.resolve()
    XCTAssertEqual(
      result,
      CodexExecutable(path: "/Users/test/bin/codex", source: "Configured")
    )
  }

  func testResolverPrefersCurrentApplicationBundleLayoutOverPathShim() async {
    let resolver = CodexExecutableResolver(
      configuredPath: nil,
      commandPathProvider: { "/Users/test/.local/bin/codex" },
      fileIsExecutable: { path in
        path == "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
          || path == "/Users/test/.local/bin/codex"
      },
      homeDirectory: URL(fileURLWithPath: "/Users/test"),
      includeFallbacks: true,
      launchServicesAppURLProvider: { _ in nil },
      runningApplicationURLsProvider: { [] }
    )

    let result = await resolver.resolve()
    XCTAssertEqual(
      result,
      CodexExecutable(
        path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        source: "/Applications"
      )
    )
  }

  func testResolverSupportsLegacyLaunchServicesBundleLayout() async {
    let resolver = CodexExecutableResolver(
      configuredPath: nil,
      commandPathProvider: { nil },
      fileIsExecutable: { $0 == "/Resolved/Codex.app/Contents/Resources/codex" },
      homeDirectory: URL(fileURLWithPath: "/Users/test"),
      includeFallbacks: true,
      launchServicesAppURLProvider: { identifier in
        XCTAssertEqual(identifier, "com.openai.codex")
        return URL(fileURLWithPath: "/Resolved/Codex.app")
      },
      runningApplicationURLsProvider: { [] }
    )

    let result = await resolver.resolve()
    XCTAssertEqual(
      result,
      CodexExecutable(path: "/Resolved/Codex.app/Contents/Resources/codex", source: "LaunchServices")
    )
  }

  func testResolverFindsRunningChatGPTAppOutsideKnownApplicationFolders() async {
    let resolver = CodexExecutableResolver(
      commandPathProvider: { "/Users/test/.local/bin/codex" },
      fileIsExecutable: { path in
        path == "/Volumes/Tools/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
          || path == "/Users/test/.local/bin/codex"
      },
      homeDirectory: URL(fileURLWithPath: "/Users/test"),
      launchServicesAppURLProvider: { _ in nil },
      runningApplicationURLsProvider: {
        [URL(fileURLWithPath: "/Volumes/Tools/ChatGPT.app")]
      }
    )

    let result = await resolver.resolve()
    XCTAssertEqual(
      result,
      CodexExecutable(
        path: "/Volumes/Tools/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        source: "LaunchServices"
      )
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

  func testResolverCanDisableFallbacksForMissingCodexFixtureState() async {
    let resolver = CodexExecutableResolver(
      configuredPath: "/missing/codex",
      commandPathProvider: { "/opt/homebrew/bin/codex" },
      fileIsExecutable: { $0 == "/opt/homebrew/bin/codex" },
      homeDirectory: URL(fileURLWithPath: "/Users/test"),
      includeFallbacks: false,
      launchServicesAppURLProvider: { _ in URL(fileURLWithPath: "/Applications/Codex.app") },
      runningApplicationURLsProvider: { [] }
    )

    let result = await resolver.resolve()
    XCTAssertNil(result)
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
