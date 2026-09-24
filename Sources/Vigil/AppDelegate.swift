import AppKit
import IOKit.pwr_mgt
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
      // The notes under the agent rows, which are one per host and wrap. A
      // setup state changing is what adds or removes a trust note or a
      // too-old note; `autoSetup` is the note Vigil writes when it has just
      // wired an agent up, and pressing its Undo takes two lines out of an
      // open panel.
      _ = model.setupStates
      _ = model.autoSetup
      // A host ageing out of `HostProbe`'s cache adds or removes a note under
      // the agent rows without touching anything else in this list.
      _ = model.hostSupports
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
    // The row counts, because the height is mostly rows: every list in this
    // panel is one 24pt row per thing it has to say, so a number with no count
    // beside it cannot be told from a regression.
    let agentRows = model.sessions.count + model.quietIntegrations.count
    print(
      "smoke: populated panel \(Int(size.width))x\(Int(size.height)) "
        + "(\(agentRows) agent rows, \(model.otherAssertions.count) ledger rows)")
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

    smokeSettings()
    smokePanelWorstCase(tallerThan: size.height)
    smokeDegraded()
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

    // The ledger, which until now the smoke test never built at all: it only
    // populates while the panel is open, so the section that carries half the
    // panel's rows was the one section never instantiated before shipping.
    // Both kinds are here — a daemon `LedgerPhrase` has a sentence for, and one
    // it deliberately does not — because they take different paths through it.
    let start = Date()
    model.loadSampleAssertions([
      SystemAssertion(
        id: "smoke-a", pid: 100, processName: "powerd",
        type: kIOPMAssertionTypePreventUserIdleSystemSleep,
        reason: "Powerd - Prevent sleep while display is on",
        startedAt: start.addingTimeInterval(-5880), timeoutSeconds: nil, timeLeft: nil),
      SystemAssertion(
        id: "smoke-b", pid: 101, processName: "coreaudiod",
        type: kIOPMAssertionTypePreventUserIdleSystemSleep,
        reason: "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep",
        startedAt: start.addingTimeInterval(-7440), timeoutSeconds: nil, timeLeft: nil),
      SystemAssertion(
        id: "smoke-c", pid: 102, processName: "Some App With A Very Long Name Indeed",
        type: kIOPMAssertionTypePreventSystemSleep,
        reason: "Uploading a rather large file to somewhere far away",
        startedAt: start.addingTimeInterval(-240), timeoutSeconds: 3600, timeLeft: 3360),
    ])
  }

  /// The hosts whose hooks a trust gate can hold shut.
  ///
  /// Derived, not counted. Both worst cases below used to hardcode Codex and
  /// the number 1 — which made the guard on the settings height unable to fire
  /// on exactly the build that needs it, since the build that gives a second
  /// host a trust gate is the build that adds a second notice. Read from the
  /// integrations, the check measures whatever the app can actually be asked to
  /// show, and fails on the version that no longer fits.
  private static let gatingHosts = AgentIntegration.all.filter(\.requiresHookTrust)

  /// Every gating host refusing at once — the worst the trust gate can do.
  private static var worstCaseTrust: [AgentKind: HookTrustState] {
    gatingHosts.reduce(into: [:]) { trust, integration in
      trust[integration.id] = .untrusted(events: integration.allEvents)
    }
  }

  /// The hosts Vigil records a version floor for.
  ///
  /// Derived for exactly the reason `gatingHosts` is, and the lesson is the
  /// same one twice: a guard that names today's only case cannot fire on the
  /// build that adds a second. One host has a floor today; the build that gives
  /// a second one a floor is the build that adds a second notice, and this
  /// measures it without anybody remembering to come back here.
  private static let flooredHosts = AgentIntegration.all.filter { $0.hookFloor != nil }

  /// Every host with a floor found only in copies below it, all at once.
  ///
  /// Two copies rather than one, because `explanation(host:)` has a longer
  /// plural branch that lists every version it found and the window has to
  /// carry the longer. The numbers are eight characters each — wider than any
  /// release either host has actually published — so a real machine's sentence
  /// can only ever measure less than the one checked here.
  private static var worstCaseHosts: [AgentKind: HostHookSupport] {
    flooredHosts.reduce(into: [:]) { hosts, integration in
      guard let floor = integration.hookFloor else { return }
      hosts[integration.id] = .tooOld(
        copies: [
          HostCopy(path: "/usr/local/bin/\(floor.executable)", version: HostVersion(0, 10, 220)),
          HostCopy(path: "/opt/homebrew/bin/\(floor.executable)", version: HostVersion(0, 12, 340)),
        ],
        needs: floor.since
      )
    }
  }

  /// An installer failure long enough to reach the line cap both the settings
  /// window and the panel hold it to, which is the number being measured: a
  /// real error — including `ClamshellInstaller.failed`, which hands an
  /// installer script's own output through untouched and has no length at all
  /// — can then only ever measure less. The sentence is the installer's real
  /// one, with the events an ordinary `~/.claude/settings.json` holds.
  private static var worstCaseSetupError: String {
    HookInstaller.InstallError.settingsShapeUnknown(
      "/Users/somebody/.claude/settings.json",
      [
        "PreToolUse", "PostToolUse", "Stop", "SubagentStop", "SessionStart", "SessionEnd",
        "Notification", "UserPromptSubmit",
      ]
    ).localizedDescription
  }

  /// Build the settings window's content and report its size.
  ///
  /// Same argument as the panel: a SwiftUI layout crash only happens when the
  /// view is instantiated, and this one is now a hand-built stack of custom
  /// controls rather than a `Form` that could be trusted to size itself. The
  /// controller is deliberately not used — `present()` flips the activation
  /// policy and puts a real window on screen, and the smoke test is supposed to
  /// leave the machine exactly as it found it.
  private func smokeSettings() {
    let hosting = NSHostingController(rootView: SettingsView(model: model))
    hosting.view.layoutSubtreeIfNeeded()
    let size = hosting.view.fittingSize

    // What the sections actually want, with the fixed height taken off. The
    // window can only stay a decision rather than a clipping mask for as long
    // as this number stays under it.
    let content = measuredSettingsContent()

    print("smoke: settings \(Int(size.width))x\(Int(size.height)) (content \(Int(content)))")
    guard size.width == Theme.Metrics.settingsWidth, size.height == Theme.Metrics.settingsHeight
    else {
      print(
        "smoke: FAILED - settings is \(Int(size.width))x\(Int(size.height)), not "
          + "\(Int(Theme.Metrics.settingsWidth))x\(Int(Theme.Metrics.settingsHeight))")
      exit(1)
    }

    // Guarded as well as printed. The worst case below covers this one by
    // construction, but a machine that overflowed while the worst case did not
    // would mean the worst case had stopped being the worst case, and that is
    // worth hearing about from the machine it happened on.
    guard content <= Theme.Metrics.settingsHeight else {
      print(
        "smoke: FAILED - settings content wants \(Int(content))pt on this machine, "
          + "which is \(Int(content - Theme.Metrics.settingsHeight))pt more than the window has")
      exit(1)
    }

    // And now the shape that actually decides whether the height holds.
    //
    // The measurement above is of this developer's machine, where `setupError`
    // is nil by construction and every host is trusted if the developer
    // trusted it — so the one input that can grow without bound was the one
    // input never exercised, and a window with a hard height and no scroll
    // view was being checked against its easiest case. The panel has
    // `MenuPanelDegradedGallery` for exactly this reason; this is the settings
    // window's half of it.
    //
    // Measured here rather than earlier, because it leaves the model holding
    // sample state. The panel's own worst case is the only thing after it that
    // reads the model, and it loads its own over the top.
    //
    // The lid section says one of two things and never both, so both shapes
    // are built and the taller one is the answer. Building both is half the
    // point on its own: a SwiftUI layout fault only happens when the view is
    // instantiated, and the helper-drift row would otherwise first be drawn on
    // the Mac of somebody whose root helper had gone out of step.
    let worst =
      [true, false].map { supported -> CGFloat in
        model.loadWorstCaseSetup(
          // Every host the trust gate can hold shut, all refusing at once. One
          // is today's answer because Codex is today's only gating host — but
          // it is read off the integrations, so the build that gives a second
          // host a gate measures two notices without anybody remembering to
          // come back here, and says so in points if they do not fit.
          trust: Self.worstCaseTrust,
          // And every host Vigil records a floor for found only in copies below
          // it. A second kind of notice under the rows, on a different host
          // from the trust one, so the window is measured with both on screen
          // — which no single Mac will ever be, and which is the whole point of
          // building the shape rather than reading one.
          host: Self.worstCaseHosts,
          error: Self.worstCaseSetupError,
          helperNotice: HelperIntegrity.State.outOfDate.notice ?? "",
          clamshellSupported: supported
        )
        return measuredSettingsContent()
      }.max() ?? 0

    // Checked rather than assumed, the same as the panel's worst case below.
    // Both notices are drawn from model state, and a fixture that stopped
    // producing one would go on measuring a window with less in it and printing
    // a number that looked fine.
    let trustNotices = model.availableIntegrations.filter {
      model.trustNotice(for: $0) != nil
    }.count
    let hostNotices = model.availableIntegrations.filter { model.hostNotice(for: $0) != nil }.count
    guard trustNotices == Self.gatingHosts.count, hostNotices == Self.flooredHosts.count else {
      print(
        "smoke: FAILED - settings worst case built \(trustNotices) trust and \(hostNotices) "
          + "host notices, not \(Self.gatingHosts.count) and \(Self.flooredHosts.count)")
      exit(1)
    }

    print(
      "smoke: settings worst case (content \(Int(worst)), "
        + "\(trustNotices) trust \(trustNotices == 1 ? "notice" : "notices"), "
        + "\(hostNotices) host \(hostNotices == 1 ? "notice" : "notices"))")
    guard worst <= Theme.Metrics.settingsHeight else {
      print(
        "smoke: FAILED - settings content wants \(Int(worst))pt at its worst, "
          + "which is \(Int(worst - Theme.Metrics.settingsHeight))pt more than the window has")
      exit(1)
    }
  }

  /// The height the sections want, with the fixed frame taken off.
  private func measuredSettingsContent() -> CGFloat {
    let fitted = NSHostingController(rootView: SettingsView(model: model, fitsToContent: true))
    fitted.view.layoutSubtreeIfNeeded()
    return fitted.view.fittingSize.height
  }

  /// Build the panel in the worst shape its notes can put it in, and measure it.
  ///
  /// The populated panel above is the panel on a good day: every host running
  /// our hooks, nothing failed, nothing accused. Under the agent rows are three
  /// notes that are only drawn on a bad one, and two of them are one *per host*
  /// rather than one at all — so the part of the panel that can grow most was
  /// the part the layout check never built. The settings window got a worst
  /// case; this is the panel's half of it.
  ///
  /// The third note, the hook-health warning, cannot be reached from here: it
  /// comes from a signal the model keeps to itself and fills from real sessions
  /// ageing out, and arranging that inside a live model is exactly what a
  /// layout check must not do. `MenuPanelDegradedGallery` builds it instead,
  /// with the rest of the chrome no fixture can reach, and `smokeDegraded`
  /// measures it.
  ///
  /// `tallerThan` is the good-day panel. The notes are the whole point of this
  /// measurement, so a worst case that did not come out taller is a worst case
  /// that built nothing.
  private func smokePanelWorstCase(tallerThan populated: CGFloat) {
    model.loadWorstCaseSetup(
      trust: Self.worstCaseTrust,
      host: Self.worstCaseHosts,
      error: Self.worstCaseSetupError,
      // Not the panel's business — it is the settings window that carries the
      // helper notice, and the lid section with it.
      helperNotice: "",
      clamshellSupported: true,
      // The fourth note, and the only one that is not about something being
      // wrong: what Vigil set up without being asked, with its undo. Every
      // agent at once, which is the longest that sentence can be and the only
      // length worth measuring — and read off the integrations, so the build
      // that ships a fifth agent measures a fifth name, and the build that
      // gives a second host a trust gate measures a second clause naming it.
      autoSetup: AgentIntegration.all
    )

    // Checked rather than assumed. Every one of these notes is drawn from
    // model state, and a fixture that stopped producing it would go on
    // measuring a panel with nothing wrong with it and reporting a number that
    // looked fine.
    let notes =
      model.untrustedIntegrations.count + model.hostsTooOld.count
      + (model.setupError == nil ? 0 : 1) + (model.autoSetup == nil ? 0 : 1)
    guard model.untrustedIntegrations.count == Self.gatingHosts.count,
      model.hostsTooOld.count == Self.flooredHosts.count, model.setupError != nil,
      model.autoSetup?.integrations.count == AgentIntegration.all.count,
      // The clause naming the hosts whose approval Vigil recorded. It is the
      // part of that sentence nobody would have assumed from "set up", so a
      // fixture that stopped building it would measure the shorter note and
      // print a number that looked fine.
      model.autoSetup?.approved.count == Self.gatingHosts.count
    else {
      print(
        "smoke: FAILED - panel worst case built \(model.untrustedIntegrations.count) trust "
          + "notices, \(model.hostsTooOld.count) host notices, "
          + "\(model.setupError == nil ? "no" : "an") error note, "
          + "\(model.autoSetup?.integrations.count ?? 0) agents set up and "
          + "\(model.autoSetup?.approved.count ?? 0) approved, not "
          + "\(Self.gatingHosts.count), \(Self.flooredHosts.count), one, "
          + "\(AgentIntegration.all.count) and \(Self.gatingHosts.count)")
      exit(1)
    }

    let panel = makePanel()
    panel.contentView?.layoutSubtreeIfNeeded()
    let size = panel.measuredContentSize()
    print("smoke: panel worst case \(Int(size.width))x\(Int(size.height)) (\(notes) notes)")

    guard size.width == Theme.Metrics.panelWidth else {
      print(
        "smoke: FAILED - panel worst case is \(Int(size.width))pt wide, not "
          + "\(Int(Theme.Metrics.panelWidth))")
      exit(1)
    }
    guard size.height > populated else {
      print(
        "smoke: FAILED - panel worst case is \(Int(size.height))pt, no taller than the "
          + "\(Int(populated))pt panel with nothing wrong with it — the notes did not lay out")
      exit(1)
    }
  }

  /// Build the panel chrome that only appears when something is wrong.
  ///
  /// The bridge notice, the blocked switch and the hook-health note cannot be
  /// reached from a fixture — one needs a socket that will not bind, one a live
  /// guardrail, and one a host that has quietly stopped reporting that its work
  /// is over. Arranging any of them on the machine running the check is
  /// precisely what a layout check must not do. `MenuPanelDegradedGallery`
  /// holds all three instead.
  private func smokeDegraded() {
    let warnings = MenuPanelDegradedGallery.healthWarnings.count
    // The health notes are composed by `HookHealth` rather than written out
    // here, so a change to what it takes before it will say anything could
    // leave this fixture silently measuring no notes at all.
    guard warnings > 0 else {
      print("smoke: FAILED - degraded chrome has no hook-health notes to measure")
      exit(1)
    }

    let hosting = NSHostingView(rootView: MenuPanelDegradedGallery())
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    print(
      "smoke: degraded chrome \(Int(size.width))x\(Int(size.height)) "
        + "(\(warnings) hook-health notes)")
    guard size.width == Theme.Metrics.panelWidth, size.height > 0 else {
      print("smoke: FAILED - degraded chrome is \(Int(size.width))pt wide")
      exit(1)
    }
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
