import AppKit
import OSLog
import SwiftUI
import VigilCore

/// `NSStatusItem` rather than SwiftUI's `MenuBarExtra`: the dropdown needs a
/// battery readout, per-session rows and programmatic dismissal, none of which
/// MenuBarExtra supports. DESIGN.md records this deviation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "app")

  private let model = AppModel()
  private var statusItem: NSStatusItem!
  private var panel: FloatingPanel?
  private var settingsWindow: SettingsWindowController?

  func applicationDidFinishLaunching(_: Notification) {
    NSApp.setActivationPolicy(.accessory)
    installStatusItem()
    model.start()

    // ⌥⌘L toggles the manual hold from anywhere.
    GlobalShortcut.register { [weak self] in
      self?.model.manualOverride.toggle()
    }

    // Redraw the status item whenever the model changes, without polling.
    observeModel()
    Self.log.info("\(Vigil.displayName, privacy: .public) launched")

    if ProcessInfo.processInfo.environment["VIGIL_SMOKE"] != nil {
      runSmokeTest()
    }
  }

  func applicationWillTerminate(_: Notification) {
    GlobalShortcut.unregister()
    model.stop()
  }

  // MARK: - Status item

  private func installStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.target = self
    statusItem.button?.action = #selector(togglePanel)
    refreshStatusItem()
  }

  private func refreshStatusItem() {
    guard let button = statusItem.button else { return }

    // Fill versus outline carries the state, never colour — which keeps it
    // legible with Differentiate Without Color enabled.
    let symbol = model.decision.holdIdleAssertion ? "eye.fill" : "eye"
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.statusLine)
    image?.isTemplate = true
    button.image = image
    button.appearsDisabled = model.isPaused

    // A count cannot be encoded in a 16pt silhouette, so it goes beside it.
    let working = model.workingCount
    button.title = working > 1 ? " \(working)" : ""
    button.setAccessibilityLabel("\(Vigil.displayName), \(model.statusLine)")
  }

  /// Observation re-registers after every change, which is how `@Observable`
  /// tracking works — one shot per observed read.
  private func observeModel() {
    withObservationTracking {
      _ = model.decision
      _ = model.sessions
      _ = model.pausedUntil
    } onChange: {
      Task { @MainActor [weak self] in
        self?.refreshStatusItem()
        self?.observeModel()
      }
    }
  }

  // MARK: - Panel

  @objc private func togglePanel() {
    if let panel, panel.isVisible {
      panel.orderOut(nil)
      model.panelBecameHidden()
      return
    }
    guard let button = statusItem.button else { return }

    model.reevaluate()

    let panel = panel ?? makePanel()
    self.panel = panel
    // The panel dismisses itself on outside clicks, so the model needs telling
    // either way — hence the callback rather than only stopping the clock here.
    panel.onDismiss = { [weak self] in self?.model.panelBecameHidden() }
    model.panelBecameVisible()
    panel.show(relativeTo: button)
  }

  private func makePanel() -> FloatingPanel {
    FloatingPanel(
      contentView: MenuPanelView(
        model: model,
        onQuit: { NSApp.terminate(nil) },
        onSettings: { [weak self] in self?.openSettings() }
      )
    )
  }

  /// Build the panel for real and report its measured size, then exit.
  ///
  /// Exists because a SwiftUI layout crash only shows up when the view is
  /// actually instantiated, and CI has no one to click the menu bar.
  private func runSmokeTest() {
    let panel = makePanel()
    panel.contentView?.layoutSubtreeIfNeeded()
    let size = panel.contentView?.fittingSize ?? .zero
    print("smoke: panel built, fitting size \(Int(size.width))x\(Int(size.height))")
    guard size.width > 0, size.height > 0 else {
      print("smoke: FAILED - panel has zero size")
      exit(1)
    }
    smokeTestHookInstall()

    print("smoke: ok")
    exit(0)
  }

  /// Run a real install and uninstall against a temporary directory.
  ///
  /// This code rewrites someone's Claude Code settings, so it should not be the
  /// one path that is never executed before shipping.
  private func smokeTestHookInstall() {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vigil-smoke-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }

    let settingsPath = temp.appendingPathComponent("settings.json").path
    let scriptPath = temp.appendingPathComponent("hooks/vigil-hook.sh").path

    func fail(_ message: String) -> Never {
      print("smoke: FAILED - \(message)")
      exit(1)
    }

    do {
      try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
      // Start from a settings file that already has someone else's hook.
      let existing =
        #"{"theme":"dark","hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/opt/other/hook.sh"}]}]}}"#
      try existing.write(toFile: settingsPath, atomically: true, encoding: .utf8)

      let installer = HookInstaller(
        scriptPath: scriptPath, settingsPath: settingsPath, integration: .claudeCode)
      guard !installer.isInstalled else { fail("reported installed before installing") }

      try installer.install()
      guard installer.isInstalled else { fail("install did not take effect") }

      // Parse rather than string-match: JSON escaping would make a textual
      // check pass or fail for reasons that have nothing to do with the merge.
      func commands(_ path: String) throws -> [String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return hooks.values.flatMap { value -> [String] in
          (value as? [[String: Any]] ?? []).flatMap { matcher in
            (matcher["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
          }
        }
      }

      let afterInstall = try commands(settingsPath)
      guard afterInstall.contains(where: { $0.contains("/opt/other/hook.sh") }) else {
        fail("clobbered another tool's hook")
      }
      guard afterInstall.contains(where: { $0.contains(scriptPath) }) else {
        fail("our own hook is missing after install")
      }
      let root =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as? [String: Any] ?? [:]
      guard root["theme"] as? String == "dark" else { fail("dropped an unrelated setting") }
      guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
        fail("hook script not installed or not executable")
      }
      guard FileManager.default.fileExists(atPath: settingsPath + ".vigil-backup") else {
        fail("no backup was written")
      }

      try installer.uninstall()
      guard !installer.isInstalled else { fail("uninstall did not take effect") }
      let final = try commands(settingsPath)
      guard final.contains(where: { $0.contains("/opt/other/hook.sh") }) else {
        fail("uninstall removed another tool's hook")
      }
      guard !final.contains(where: { $0.contains(scriptPath) }) else {
        fail("uninstall left our hook behind")
      }

      print("smoke: hook install/uninstall cycle ok")
    } catch {
      fail("hook install threw: \(error.localizedDescription)")
    }
  }

  private func openSettings() {
    panel?.orderOut(nil)
    let controller = settingsWindow ?? SettingsWindowController(model: model)
    settingsWindow = controller
    controller.present()
  }
}
