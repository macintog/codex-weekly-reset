import AppKit
import SwiftUI

struct NativeActionButton: NSViewRepresentable {
  let title: String
  let systemImage: String
  let accessibilityIdentifier: String
  let isEnabled: Bool
  let action: () -> Void

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(
      title: title,
      target: context.coordinator,
      action: #selector(Coordinator.activateButton)
    )
    button.bezelStyle = NSButton.BezelStyle.rounded
    button.controlSize = NSControl.ControlSize.regular
    button.imagePosition = NSControl.ImagePosition.imageLeading
    button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
    button.setAccessibilityIdentifier(accessibilityIdentifier)
    button.setAccessibilityLabel(title)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    button.title = title
    button.isEnabled = isEnabled
    button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
    button.setAccessibilityIdentifier(accessibilityIdentifier)
    button.setAccessibilityLabel(title)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(action: action)
  }

  final class Coordinator: NSObject {
    var action: () -> Void

    init(action: @escaping () -> Void) {
      self.action = action
    }

    @objc func activateButton(_ sender: NSButton) {
      action()
    }
  }
}
