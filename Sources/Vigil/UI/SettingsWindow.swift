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
    window.center()
    self.init(window: window)
    self.model = model
    window.delegate = self
  }

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
