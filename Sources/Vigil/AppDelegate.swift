import AppKit
import OSLog
import VigilCore

/// `NSStatusItem` rather than SwiftUI's `MenuBarExtra`: the dropdown needs a
/// battery bar, per-session rows and programmatic dismissal, none of which
/// MenuBarExtra supports. Ice, Maccy and Rectangle all reached the same place.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "app")

  private var statusItem: NSStatusItem!
  private let assertion = PowerAssertion()
  private let clamshell = ClamshellController()

  private var sessions = SessionStore()
  private var settings = WakeSettings()
  private var manualOverride = false
  private var pausedUntil: Date?
  private var decision = WakeDecision(
    holdIdleAssertion: false, disableClamshellSleep: false, reason: .noAgents)

  private var tick: Timer?
  private var bridge: EventBridge?

  func applicationDidFinishLaunching(_: Notification) {
    NSApp.setActivationPolicy(.accessory)
    installStatusItem()

    bridge = EventBridge { [weak self] event in self?.handle(event) }
    bridge?.start()

    // One timer drives expiry, battery sampling and the wake decision. Agent
    // events arrive asynchronously and re-evaluate immediately.
    tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.reevaluate() }
    }
    reevaluate()
    Self.log.info("\(Vigil.displayName, privacy: .public) launched")
  }

  func applicationWillTerminate(_: Notification) {
    bridge?.stop()
    assertion.release()
    clamshell.restoreOnExit()
  }

  private func installStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.setAccessibilityLabel("\(Vigil.displayName), Mac may sleep")
    refreshStatusItem()

    let menu = NSMenu()
    menu.addItem(
      withTitle: "Keep Awake", action: #selector(toggleOverride), keyEquivalent: ""
    )
    .target = self
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit \(Vigil.displayName)", action: #selector(quit), keyEquivalent: "q"
    )
    .target = self
    statusItem.menu = menu
  }

  private func refreshStatusItem() {
    guard let button = statusItem.button else { return }
    // Filled vs outline, never colour: the menu bar renders template images
    // monochrome, and this stays legible with Differentiate Without Color on.
    let symbol = decision.holdIdleAssertion ? "eye.fill" : "eye"
    button.image = NSImage(
      systemSymbolName: symbol, accessibilityDescription: statusDescription)
    button.image?.isTemplate = true
    button.appearsDisabled = pausedUntil.map { $0 > Date() } ?? false

    let active = sessions.active().count
    button.title = active > 1 ? " \(active)" : ""
    button.setAccessibilityLabel("\(Vigil.displayName), \(statusDescription)")
  }

  private var statusDescription: String {
    switch decision.reason {
    case .agentsWorking(let count):
      "awake - \(count) agent\(count == 1 ? "" : "s") working"
    case .manualOverride: "awake - kept awake manually"
    case .paused(let until):
      "paused until \(until.formatted(date: .omitted, time: .shortened))"
    case .noAgents: "Mac may sleep - no agents running"
    case .batteryBelowFloor(let percent, let floor):
      "sleeping - battery \(percent)% is below the \(floor)% floor"
    case .onBatteryAndPluggedInRequired: "sleeping - set to run only on mains power"
    case .lowPowerMode: "sleeping - Low Power Mode is on"
    }
  }

  private func reevaluate() {
    sessions.prune()
    decision = WakePolicy.decide(
      sessions: sessions.all(),
      conditions: PowerMonitor.current(),
      settings: settings,
      manualOverride: manualOverride,
      pausedUntil: pausedUntil
    )

    if decision.holdIdleAssertion {
      assertion.hold(reason: statusDescription)
    } else {
      assertion.release()
    }
    Task { await clamshell.setSleepDisabled(decision.disableClamshellSleep) }
    refreshStatusItem()
  }

  /// Called from the bridge when a hook reports in.
  func handle(_ event: AgentEvent) {
    sessions.apply(event)
    reevaluate()
  }

  @objc private func toggleOverride() {
    manualOverride.toggle()
    reevaluate()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
