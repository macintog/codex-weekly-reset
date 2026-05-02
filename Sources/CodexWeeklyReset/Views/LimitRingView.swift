import SwiftUI

struct LimitRingView: View {
  let percent: Double?
  var size: CGFloat = 72
  var lineWidth: CGFloat = 8

  private var fraction: Double {
    min(1, max(0, (percent ?? 0) / 100))
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
        .trim(from: 0, to: fraction)
        .stroke(
          color.gradient,
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        .rotationEffect(.degrees(-90 + capAlignmentDegrees))
    }
    .frame(width: size, height: size)
    .accessibilityIdentifier("weeklyRemainingRing")
    .accessibilityLabel("Weekly remaining ring")
    .accessibilityValue(percent.map(DisplayFormatters.percentage) ?? "Unknown")
  }
}
