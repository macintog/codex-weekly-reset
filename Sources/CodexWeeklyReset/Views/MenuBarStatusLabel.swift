import AppKit
import SwiftUI

struct MenuBarStatusLabel: View {
  let state: MonitorState
  let isRefreshing: Bool

  private var presentation: MenuBarLimitPresentation {
    MenuBarLimitPresentation(state: state)
  }

  var body: some View {
    Image(nsImage: MenuBarLimitGlyphImage.image(for: presentation))
      .resizable()
      .interpolation(.high)
      .antialiased(true)
      .frame(width: 18, height: 18)
      .opacity(isRefreshing ? 0.72 : 1)
      .accessibilityIdentifier("menuBarStatusLabel")
      .accessibilityLabel("Codex weekly remaining")
      .accessibilityValue(presentation.accessibilityValue)
  }
}

struct MenuBarLimitPresentation: Equatable {
  let fraction: Double
  let band: QuotaIndicatorBand
  let filledCells: Int
  let accessibilityValue: String

  init(state: MonitorState) {
    switch state {
    case .idle, .loading:
      fraction = 0
      band = .unknown
      filledCells = 0
      accessibilityValue = "Checking"
    case let .ready(snapshot):
      fraction = min(1, max(0, snapshot.remainingPercent / 100))
      filledCells = QuotaIndicatorSlots.filledSlots(forRemainingPercent: snapshot.remainingPercent)
      band = QuotaIndicatorBand(filledSlots: filledCells)
      accessibilityValue = "\(DisplayFormatters.percentage(snapshot.remainingPercent)) weekly remaining"
    case .failed:
      fraction = 0
      band = .failed
      filledCells = 0
      accessibilityValue = "Unavailable"
    }
  }

}

enum MenuBarLimitGlyphImage {
  static func image(for presentation: MenuBarLimitPresentation) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.lockFocus()
    defer {
      image.unlockFocus()
    }

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    let color = color(for: presentation.band)
    let outlineColor = NSColor.labelColor
    let emptyOutlineColor = outlineColor.withAlphaComponent(0.36)
    let cellWidth: CGFloat = 4
    let cellHeight: CGFloat = 3.6
    let slant: CGFloat = 1.05
    let gapX: CGFloat = 1.25
    let gapY: CGFloat = 1.6
    let origin = CGPoint(x: 1.8, y: 2.6)

    for index in 0..<9 {
      let row = index / 3
      let column = index % 3
      let x = origin.x + CGFloat(column) * (cellWidth + gapX)
      let y = origin.y + CGFloat(2 - row) * (cellHeight + gapY)
      let path = cellPath(
        x: x,
        y: y,
        width: cellWidth,
        height: cellHeight,
        slant: slant
      )

      if isFilledCell(index, filledCells: presentation.filledCells) {
        color.setFill()
        path.fill()
        outlineColor.setStroke()
      } else {
        emptyOutlineColor.setStroke()
      }

      path.lineWidth = 0.7
      path.stroke()
    }

    image.isTemplate = presentation.band == .healthy || presentation.band == .unknown
    return image
  }

  private static func color(for band: QuotaIndicatorBand) -> NSColor {
    switch band {
    case .unknown, .healthy:
      return .labelColor
    case .caution:
      return .systemOrange
    case .alarm, .failed:
      return .systemRed
    }
  }

  static func isFilledCell(_ index: Int, filledCells: Int) -> Bool {
    index >= 9 - filledCells
  }

  private static func cellPath(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    slant: CGFloat
  ) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: x, y: y))
    path.line(to: CGPoint(x: x + width, y: y))
    path.line(to: CGPoint(x: x + width + slant, y: y + height))
    path.line(to: CGPoint(x: x + slant, y: y + height))
    path.close()
    return path
  }
}
