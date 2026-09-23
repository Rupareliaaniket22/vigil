import AppKit
import OSLog
import SwiftUI

/// The dropdown window, anchored under the status item.
///
/// A borderless `NSPanel` hosting SwiftUI rather than SwiftUI's own
/// `MenuBarExtra`, which cannot render the battery meter, the per-session rows
/// or the assertion ledger, and offers no way to dismiss itself
/// programmatically. DESIGN.md records this as a deliberate deviation.
final class FloatingPanel: NSPanel {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "panel")

  /// Called whenever the panel goes away, including the click-outside path
  /// that `resignKey` handles without anyone asking us to close.
  var onDismiss: (() -> Void)?

  /// When the panel last took itself off screen.
  ///
  /// Clicking the status item while the panel is key resigns key *first* — the
  /// status bar's own window becomes key on mouse-down — so by the time the
  /// button's action runs, the panel has already dismissed itself and a check
  /// on `isVisible` reads "closed, so open it". The panel flickered shut and
  /// straight back open, and the status item could not be used to close it.
  private var dismissedAt: ContinuousClock.Instant?
  /// Guards against `orderOut` re-entering through `resignKey`.
  private var isDismissing = false

  /// Whether this panel closed itself moments ago — long enough ago to be a
  /// separate gesture is 250ms, which is also the double-click interval.
  var wasJustDismissed: Bool {
    guard let dismissedAt else { return false }
    return dismissedAt.duration(to: .now) < .milliseconds(250)
  }

  /// Kept so the panel can re-anchor itself when its content resizes.
  private weak var anchorButton: NSStatusBarButton?
  private weak var hosting: NSView?

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

    self.hosting = hosting
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

  /// Escape dismisses, the way a popover does. Without this the panel is a
  /// popover-shaped thing with no keyboard way out.
  override func cancelOperation(_: Any?) {
    dismiss()
  }

  /// ⌘W, routed to the one exit this panel has.
  ///
  /// The main menu installs a Window ▸ Close item at launch — the settings
  /// window needs it — with a nil target, so it dispatches down the responder
  /// chain to whatever window is key. This one is created without `.closable`,
  /// and `NSWindow.performClose(_:)` on a window with no close button has
  /// nothing to simulate: it beeps. ⌘W is the reflex gesture for dismissing a
  /// focused surface, and the panel answered it with an error sound.
  ///
  /// Routed here rather than fixed by adding `.closable`: `dismiss()` is the
  /// one way this panel goes away, and a close that went round it would order
  /// the window out without `onDismiss`, stranding the display clock exactly
  /// as that method's own comment describes. Escape already comes through
  /// `cancelOperation`; this puts ⌘W on the same path.
  ///
  /// Unreachable on its own. `validateMenuItem(_:)` below is what lets the
  /// menu item this hangs off actually fire.
  override func performClose(_: Any?) {
    dismiss()
  }

  /// Let Window ▸ Close fire on this panel.
  ///
  /// AppKit validates that item before performing it, and `NSWindow`'s own
  /// validation answers for `performClose(_:)` by looking for a close button.
  /// This panel is built without `.closable` and has none, so the item was
  /// disabled for as long as the panel was the target — and a disabled item
  /// still *matches* the key equivalent: the menu reported the keystroke
  /// handled and performed nothing. ⌘W did nothing at all, `performClose(_:)`
  /// above was never called once, and the method, DESIGN.md and the changelog
  /// all described a gesture no code was running.
  ///
  /// So the panel answers for that one action itself — it can close;
  /// `dismiss()` is how, whatever its style mask says about buttons — and
  /// leaves every other item to `NSWindow`.
  override func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(performClose(_:)) { return true }
    return super.validateMenuItem(item)
  }

  /// Dismiss when the user clicks elsewhere, the way a popover does.
  override func resignKey() {
    super.resignKey()
    guard NSApp.modalWindow == nil else { return }
    dismiss()
  }

  /// The one way this panel goes away, so nothing can close it without the
  /// model hearing about it — an `orderOut` that skipped `onDismiss` left the
  /// display clock ticking against a panel nobody could see.
  func dismiss() {
    guard isVisible, !isDismissing else { return }
    isDismissing = true
    defer { isDismissing = false }
    orderOut(nil)
    dismissedAt = .now
    onDismiss?()
  }

  /// Position beneath a status item and show.
  ///
  /// The frame is clamped to the screen's visible area so a status item near
  /// the right edge doesn't push the panel off-screen or onto another display.
  func show(relativeTo button: NSStatusBarButton) {
    guard let buttonWindow = button.window else { return }
    anchorButton = button

    resizeToFit(near: buttonWindow)

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
    dismissedAt = nil
    makeKeyAndOrderFront(nil)
    openWithNothingFocused()
  }

  /// A menu highlights nothing until an arrow key is pressed, and this panel
  /// is a menu in all but class.
  ///
  /// Becoming key hands the first responder to SwiftUI's key-view proxy, which
  /// then focuses the first focusable view it has — so every open began with a
  /// focus ring drawn around the first row for a keyboard nobody had touched,
  /// and it was the loudest thing on screen. Worse, the proxy stays first
  /// responder while the panel is ordered out, so the *second* open came back
  /// with whichever row was last lit still lit.
  ///
  /// Cleared after `makeKeyAndOrderFront`, not before: becoming key is what
  /// assigns the focus, so clearing first is undone a line later. Handing the
  /// window itself the first responder is what SwiftUI reads as "nothing
  /// focused", and the key-view loop is untouched, so Tab still reaches the
  /// first row.
  ///
  /// The result is checked because it can be `false`. Apple documents that
  /// passing `nil` still sends `resignFirstResponder()` to whatever holds the
  /// status, and that "if the current first responder refuses to resign, it
  /// remains the first responder and this method immediately returns `false`"
  /// — and a refusal here is silent and looks exactly like the focus-ring bug
  /// this method was written to fix.
  private func openWithNothingFocused() {
    if makeFirstResponder(nil) { return }

    // A field editor mid-validation is the usual refuser. AppKit's own
    // documented order for that is the order here: ask the window nicely
    // first, and reach for `endEditing(for:)` "only as a last resort if the
    // field editor refuses to resign first responder status".
    endEditing(for: nil)
    if makeFirstResponder(nil) { return }

    // Twice refused. Nothing left to try that would not be worse than the
    // symptom, so record it: the visible result is a focus ring around a row
    // nobody touched, which has been reported as "the panel looks wrong" and
    // is hard to recognise from a screenshot alone.
    Self.log.notice("panel opened with something still focused; first responder refused to resign")
  }

  /// Arrow keys from nothing focused start keyboard navigation, the way they
  /// do in a menu: down or right lands on the first row, up or left on the
  /// last. With the window as first responder AppKit already turns Tab into
  /// `selectNextKeyView`, but treats arrows as nothing at all, and a panel
  /// that opens with no focus has to answer the first key that asks for some.
  /// Once a row holds focus the proxy is first responder and the arrows go to
  /// SwiftUI, so this never sees them.
  override func keyDown(with event: NSEvent) {
    guard firstResponder === self, let key = event.charactersIgnoringModifiers?.unicodeScalars.first
    else {
      super.keyDown(with: event)
      return
    }
    switch Int(key.value) {
    case NSDownArrowFunctionKey, NSRightArrowFunctionKey:
      selectNextKeyView(nil)
    case NSUpArrowFunctionKey, NSLeftArrowFunctionKey:
      selectPreviousKeyView(nil)
    default:
      super.keyDown(with: event)
    }
  }

  /// Re-fit after the content grows or shrinks while the panel is open, and
  /// keep it anchored under the status item.
  func refitIfVisible() {
    guard isVisible, let button = anchorButton, let buttonWindow = button.window else { return }
    let previousHeight = frame.height
    resizeToFit(near: buttonWindow)
    guard frame.height != previousHeight else { return }
    // Grow downwards from the same top edge rather than from the bottom.
    setFrameOrigin(NSPoint(x: frame.origin.x, y: frame.origin.y + previousHeight - frame.height))
  }

  /// The height SwiftUI wants, resolved through the constraint system.
  ///
  /// Measured from the effect view, not the hosting view: the hosting view is
  /// pinned to its superview's edges, so its own fitting size is whatever the
  /// window already is. (`sizingOptions = .preferredContentSize` would invert
  /// that, but fights the same constraints and yields zero.)
  func measuredContentSize() -> NSSize {
    contentView?.layoutSubtreeIfNeeded()
    let height = contentView?.fittingSize.height ?? frame.height
    return NSSize(width: Theme.Metrics.panelWidth, height: height)
  }

  private func resizeToFit(near buttonWindow: NSWindow) {
    let fitting = measuredContentSize().height
    // Never taller than the screen it sits on. Nothing scrolls, so every
    // section that can grow without bound caps itself and says how many it is
    // not showing; this clamp is the backstop, not the mechanism.
    let ceiling = (buttonWindow.screen?.visibleFrame.height ?? 800) - 24
    setContentSize(NSSize(width: Theme.Metrics.panelWidth, height: min(fitting, ceiling)))
  }
}
