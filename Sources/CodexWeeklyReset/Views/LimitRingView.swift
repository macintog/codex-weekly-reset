import SwiftUI

struct LimitRingView: View {
  let percent: Double?
  var size: CGFloat = 72
  var lineWidth: CGFloat = 8

  private var geometry: LimitRingGeometry {
    LimitRingGeometry(percent: percent, size: size, lineWidth: lineWidth)
  }

  private var color: Color {
    guard let percent else {
      return .secondary
    }

    switch QuotaIndicatorSlots.band(forRemainingPercent: percent) {
    case .unknown, .failed:
      return .secondary
    case .healthy:
      return .green
    case .caution:
      return .orange
    case .alarm:
      return .red
    }
  }

  private var capAlignmentDegrees: Double {
    let radius = max(1, (size - lineWidth) / 2)
    let radians = Double((lineWidth / 2) / radius)
    return radians * 180 / .pi
  }

  var body: some View {
    ZStack {
      Circle()
        .stroke(.quaternary, lineWidth: lineWidth)

      Circle()
        .trim(from: 0, to: geometry.trimmedFraction)
        .stroke(
          color.gradient,
          style: StrokeStyle(
            lineWidth: lineWidth,
            lineCap: geometry.usesRoundCaps ? .round : .butt
          )
        )
        .rotationEffect(
          .degrees(geometry.usesRoundCaps ? -90 + capAlignmentDegrees : -90)
        )
    }
    .frame(width: size, height: size)
    .accessibilityIdentifier("weeklyRemainingRing")
    .accessibilityLabel("Weekly remaining ring")
    .accessibilityValue(percent.map(DisplayFormatters.percentage) ?? "Unknown")
  }
}

struct LimitRingGeometry {
  let fraction: Double
  let trimmedFraction: Double
  let usesRoundCaps: Bool

  init(percent: Double?, size: CGFloat, lineWidth: CGFloat) {
    fraction = min(1, max(0, (percent ?? 0) / 100))

    let radius = max(1, Double((size - lineWidth) / 2))
    let roundCapsFraction = Double(lineWidth) / (2 * .pi * radius)

    if fraction == 0 || fraction == 1 {
      trimmedFraction = fraction
      usesRoundCaps = fraction == 1
    } else if fraction <= roundCapsFraction {
      trimmedFraction = fraction
      usesRoundCaps = false
    } else {
      trimmedFraction = fraction - roundCapsFraction
      usesRoundCaps = true
    }
  }
}
