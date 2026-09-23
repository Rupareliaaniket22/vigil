import AppKit
import SwiftUI

/// Owns the settings window directly rather than using SwiftUI's `Settings`
/// scene.
///
/// An accessory app has no Dock icon, and macOS won't let a window from one
/// become key — `SettingsLink` and `openSettings()` both fail to bring it
/// forward, sometimes silently. Switching activation policy around the window's
/// lifetime is the reliable way, and is what Ice does.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

  private weak var model: AppModel?

  convenience init(model: AppModel) {
    let hosting = NSHostingController(rootView: SettingsView(model: model))
    let window = NSWindow(contentViewController: hosting)
    window.title = "Vigil Settings"

    // `.titled` and `.closable` stay. Dropping the title bar entirely — a
    // `.borderless` window — takes ⌘W and dragging with it, and a settings
    // window you cannot move or close from the keyboard is a worse trade than
    // the 28pt it saves.
    //
    // What goes is the *look* of it: no bar, no title, content running up
    // behind the traffic lights. SettingsView leaves them their clearance.
    window.styleMask = [.titled, .closable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden

    window.isReleasedWhenClosed = false
    self.init(window: window)
    self.model = model
    window.delegate = self

    // Where the user last left it, across launches and not only within one.
    // With no autosave name the window remembered its position until quit and
    // then reverted to the centre of the main display — so a second monitor is
    // somewhere this window can be put but never somewhere it stays.
    //
    // Cascading off, because the frame is set here: left on, `NSWindowController`
    // nudges the restored window down and right by a title bar on every open,
    // and a window that walks across the screen is worse than one that forgets.
    shouldCascadeWindows = false
    window.setFrameAutosaveName(Self.frameAutosaveName)
    if window.setFrameUsingName(Self.frameAutosaveName) {
      // A saved frame carries a size as well as a position, and the size is
      // not the user's to keep: it is `Theme.Metrics`, and a build that
      // changes it would otherwise reopen at whatever the last build was. The
      // position is restored, the size is re-asserted.
      window.setContentSize(
        NSSize(width: Theme.Metrics.settingsWidth, height: Theme.Metrics.settingsHeight))
    } else {
      // Nothing saved yet. Centring is the right first position and the wrong
      // every-other one, which is the whole of this fix.
      window.center()
    }
  }

  /// A key of its own rather than the window's title. The title is interface
  /// text and could reasonably be reworded; the name this frame is stored
  /// under must not change when it is, or everyone's saved position is thrown
  /// away by a copy edit.
  private static let frameAutosaveName = NSWindow.FrameAutosaveName("VigilSettingsWindow")

  func present() {
    model?.refreshLaunchAtLogin()
    // Become a regular app just long enough to own a real window.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_: Notification) {
    // Back to the menu bar, or we'd leave a Dock icon behind.
    NSApp.setActivationPolicy(.accessory)
  }
}
