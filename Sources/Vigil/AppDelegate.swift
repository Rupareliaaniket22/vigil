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
    // Before anything that touches shared state: the smoke test builds the
    // panel and exits, and must not disturb a running instance's socket.
    if ProcessInfo.processInfo.environment["VIGIL_SMOKE"] != nil {
      runSmokeTest()
    }

    NSApp.setActivationPolicy(.accessory)
    installMainMenu()
    installStatusItem()
    model.start()

    // ⌥⌘L toggles the manual hold from anywhere.
    let registered = GlobalShortcut.register { [weak self] in
      self?.model.manualOverride.toggle()
    }
    if !registered {
      // Swallowing this leaves the user pressing a shortcut that silently
      // belongs to another app.
      model.noteShortcutUnavailable()
    }

    // Redraw the status item whenever the model changes, without polling.
    observeModel()
    Self.log.info("\(Vigil.displayName, privacy: .public) launched")
  }

  func applicationWillTerminate(_: Notification) {
    GlobalShortcut.unregister()
    model.stop()
  }

  // MARK: - Status item

  private func installStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // Deliberately not .removalAllowed: this is the app's only entry point, and
    // NSStatusItem persists visibility across launches, so a stray ⌘-drag would
    // make Vigil permanently unreachable.
    statusItem.button?.target = self
    statusItem.button?.action = #selector(togglePanel)
    refreshStatusItem()
  }

  /// A minimal main menu.
  ///
  /// The Settings window switches the app to `.regular`, and a regular app with
  /// no main menu gets a bare menu bar: ⌘W will not close its window and ⌘Q
  /// will not quit. Building one once at launch fixes both.
  private func installMainMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ","
    )
    .target = self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit \(Vigil.displayName)", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)

    NSApp.mainMenu = main
  }

  @objc private func openSettingsFromMenu() {
    openSettings()
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
      // Not for the status item — for the panel's height. Every one of these
      // adds or removes a row while the panel may be open.
      _ = model.otherAssertions
      _ = model.installedAgents
      _ = model.availableIntegrations
      _ = model.setupError
      _ = model.bridgeError
    } onChange: {
      Task { @MainActor [weak self] in
        self?.refreshStatusItem()
        // Content that grew or shrank while the panel is open would otherwise
        // be clipped: the hosting view is pinned to the window, and the window
        // was sized once, when it opened.
        self?.panel?.refitIfVisible()
        self?.observeModel()
      }
    }
  }

  // MARK: - Panel

  @objc private func togglePanel() {
    if let panel, panel.isVisible {
      panel.dismiss()
      return
    }
    // Clicking the status item while the panel was key already dismissed it,
    // before this action ran. Reopening here would make the status item unable
    // to close the panel at all.
    if let panel, panel.wasJustDismissed { return }
    guard let button = statusItem.button else { return }

    let panel = panel ?? makePanel()
    self.panel = panel
    // The panel dismisses itself on outside clicks, so the model needs telling
    // either way — hence the callback rather than only stopping the clock here.
    panel.onDismiss = { [weak self] in self?.model.panelBecameHidden() }
    // Re-reads everything the panel shows, including the readings that are
    // only sampled while it is open.
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
    let empty = makePanel()
    empty.contentView?.layoutSubtreeIfNeeded()
    let emptySize = empty.measuredContentSize()
    print("smoke: empty panel \(Int(emptySize.width))x\(Int(emptySize.height))")
    guard emptySize.width > 0, emptySize.height > 0 else {
      print("smoke: FAILED - panel has zero size")
      exit(1)
    }

    // Now with content. Building an empty panel never instantiated a session
    // row, an agent row or the ledger, so the views most likely to break at a
    // realistic content length were the ones the smoke test did not cover.
    model.refreshInstalledAgents()
    smokeContent()

    let full = makePanel()
    full.contentView?.layoutSubtreeIfNeeded()
    let size = full.measuredContentSize()
    print("smoke: populated panel \(Int(size.width))x\(Int(size.height))")
    guard size.height > emptySize.height else {
      print("smoke: FAILED - rows did not lay out")
      exit(1)
    }
    // Width is the design contract; a row that refuses to compress would push
    // it out rather than truncate, and nothing else would notice.
    guard size.width == Theme.Metrics.panelWidth else {
      print("smoke: FAILED - panel is \(size.width)pt wide, not \(Theme.Metrics.panelWidth)")
      exit(1)
    }

    smokeTestHookInstall()

    print("smoke: ok")
    exit(0)
  }

  /// Feed the panel the content it has to survive: long paths, every session
  /// state, an agent we ship no integration for, and a prompt that is nothing
  /// but wide characters.
  ///
  /// View state only — see `loadSampleSessions`. A smoke test that changed the
  /// power state of the machine running it would be worse than no smoke test.
  private func smokeContent() {
    let deep = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("code/a-rather-long-project-name/packages/server").path
    let events = [
      AgentEvent(
        agent: .claudeCode, sessionID: "smoke-1", state: .working, event: "PreToolUse",
        cwd: deep, title: String(repeating: "ええ", count: 60)),
      AgentEvent(
        agent: .codex, sessionID: "smoke-1", state: .waiting, event: "PreToolUse", cwd: "/"),
      AgentEvent(agent: .cursor, sessionID: "smoke-3", state: .idle, event: "stop", cwd: deep),
      AgentEvent(
        agent: AgentKind(rawValue: "some-new-tool"), sessionID: "smoke-4", state: .working),
    ]
    model.loadSampleSessions(events)
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
    panel?.dismiss()
    let controller = settingsWindow ?? SettingsWindowController(model: model)
    settingsWindow = controller
    controller.present()
  }
}
