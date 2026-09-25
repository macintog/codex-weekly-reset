import Foundation

/// The supplied measurement includes application padding, but no native chrome.
/// Never derive it from the outer window's allocated content bounds.
enum PopoverContentGeometry {
  static func targetSize(measured: CGSize, maximum: CGSize, scale: CGFloat) -> CGSize? {
    guard measured.width.isFinite, measured.height.isFinite,
          measured.width > 0, measured.height > 0,
          maximum.width.isFinite, maximum.height.isFinite,
          maximum.width > 0, maximum.height > 0,
          scale.isFinite, scale > 0 else { return nil }
    func rounded(_ value: CGFloat, maximum: CGFloat) -> CGFloat {
      min(ceil(value * scale) / scale, floor(maximum * scale) / scale)
    }
    let target = CGSize(width: rounded(measured.width, maximum: maximum.width),
                        height: rounded(measured.height, maximum: maximum.height))
    return target.width > 0 && target.height > 0 ? target : nil
  }

  static func differs(_ first: CGSize, _ second: CGSize, scale: CGFloat) -> Bool {
    guard scale.isFinite, scale > 0 else { return false }
    let tolerance = 0.5 / scale
    return abs(first.width - second.width) > tolerance || abs(first.height - second.height) > tolerance
  }
}
