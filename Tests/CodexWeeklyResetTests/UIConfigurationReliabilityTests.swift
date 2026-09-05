import AppKit
import XCTest
@testable import CodexWeeklyReset

final class UIConfigurationReliabilityTests: XCTestCase {
  func testPollIntervalRejectsNonfiniteAndBoundsFiniteValues() {
    for value in ["inf", "-inf", "nan", "invalid"] {
      XCTAssertEqual(configuration(value).pollInterval, 300, value)
    }
    XCTAssertEqual(configuration("1e20").pollInterval, 86_400)
    XCTAssertEqual(configuration("-1").pollInterval, 5)
    XCTAssertEqual(configuration("0").pollInterval, 5)
    XCTAssertEqual(configuration("12.5").pollInterval, 12.5)
    let environment = AppConfiguration.live(
      environment: ["CODEX_WEEKLY_RESET_POLL_INTERVAL": "inf"], arguments: []
    )
    XCTAssertEqual(environment.pollInterval, 300)
  }

  @MainActor
  func testEmptyAlarmAndFailureGlyphsActuallyPaintRed() throws {
    _ = NSApplication.shared
    let exhausted = RateLimitSnapshot(
      limitId: "codex", limitName: nil, usedPercent: 100, remainingPercent: 0,
      windowDurationMins: 10_080, resetsAt: Date(), checkedAt: Date(),
      planType: nil, sourcePath: "test", resetCredits: nil
    )
    for state in [MonitorState.ready(exhausted), .failed("Unavailable")] {
      let image = MenuBarLimitGlyphImage.image(for: MenuBarLimitPresentation(state: state))
      XCTAssertFalse(image.isTemplate)
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
      XCTAssertGreaterThan(redPixels, 0, "An empty alarm glyph must still visibly carry red")
    }
  }

  private func configuration(_ interval: String) -> AppConfiguration {
    AppConfiguration.live(environment: [:], arguments: ["test", "--poll-interval", interval])
  }
}
