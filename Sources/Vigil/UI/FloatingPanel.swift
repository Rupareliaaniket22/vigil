import AppKit
import SwiftUI

/// The dropdown window, anchored under the status item.
///
/// A borderless `NSPanel` hosting SwiftUI rather than SwiftUI's own
/// `MenuBarExtra`, which cannot render the battery meter, the per-session rows
/// or the assertion ledger, and offers no way to dismiss itself
/// programmatically. DESIGN.md records this as a deliberate deviation.
final class FloatingPanel: NSPanel {

  init(contentView: some View) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: Theme.Metrics.panelWidth, height: 200),
      // .nonactivatingPanel keeps the frontmost app frontmost — opening Vigil
      // must not steal focus from the editor someone is watching.
      styleMask: [.nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    // Opening a menu bar panel is among the most frequent interactions in
    // macOS. It should feel instant, so the window does not animate.
    animationBehavior = .none

    isFloatingPanel = true
    // Above the autofill layer that browsers put at 999, or the panel is
    // invisible with Chrome frontmost.
    level = .screenSaver
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]

    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovable = false
    hidesOnDeactivate = false
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true

    let hosting = NSHostingView(rootView: contentView)
    hosting.wantsLayer = true
    hosting.layer?.cornerRadius = Theme.Metrics.cornerRadius
    // The real squircle, not a circular-arc corner.
    hosting.layer?.cornerCurve = .continuous
    hosting.layer?.masksToBounds = true

    let effect = NSVisualEffectView()
    // Semantically a popover — transient and anchored — even though it is a
    // custom panel. Materials are chosen by intended use, not appearance.
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = Theme.Metrics.cornerRadius
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true

    effect.addSubview(hosting)
    hosting.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: effect.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])

    self.contentView = effect
  }

  /// Text fields inside the panel need this to accept typing.
  override var canBecomeKey: Bool { true }

  /// Dismiss when the user clicks elsewhere, the way a popover does.
  override func resignKey() {
    super.resignKey()
    guard NSApp.modalWindow == nil else { return }
    orderOut(nil)
  }

  /// Position beneath a status item and show.
  ///
  /// The frame is clamped to the screen's visible area so a status item near
  /// the right edge doesn't push the panel off-screen or onto another display.
  func show(relativeTo button: NSStatusBarButton) {
    guard let buttonWindow = button.window else { return }

    contentView?.layoutSubtreeIfNeeded()
    let size = contentView?.fittingSize ?? frame.size
    setContentSize(NSSize(width: Theme.Metrics.panelWidth, height: size.height))

    let inWindow = button.convert(button.bounds, to: nil)
    let onScreen = buttonWindow.convertToScreen(inWindow)

    var origin = NSPoint(
      x: onScreen.midX - frame.width / 2,
      y: onScreen.minY - frame.height - 6
    )

    if let visible = buttonWindow.screen?.visibleFrame {
      origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
      origin.y = max(origin.y, visible.minY + 8)
    }

    setFrameOrigin(origin)
    makeKeyAndOrderFront(nil)
  }
}
