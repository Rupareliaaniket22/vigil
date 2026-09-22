import AppKit
import Foundation
import OSLog
import Observation
import VigilCore

/// Everything the panel displays and acts on.
///
/// Holds the app-layer state and owns the side effects — the power assertion,
/// the clamshell backend, the hook bridge. The decision itself is computed by
/// `WakePolicy` in VigilCore, which knows nothing about any of this.
@MainActor
@Observable
final class AppModel {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "model")

  // MARK: - Observable state

  private(set) var sessions: [AgentSession] = []
  private(set) var decision = WakeDecision(
    holdIdleAssertion: false, disableClamshellSleep: false, reason: .noAgents)
  private(set) var power = PowerConditions()
  /// Assertions held by every process, ours included. The panel shows the
  /// others so the user learns when the answer isn't us.
  private(set) var otherAssertions: [SystemAssertion] = []

  /// The clock the panel renders elapsed times against.
  ///
  /// Only ticks while the panel is open. Reading `Date()` inside a row would
  /// freeze the moment SwiftUI stopped re-rendering, and re-rendering on a
  /// timer regardless of visibility is work a power utility has no business
  /// doing when nobody is looking.
  private(set) var now = Date()
  private var clock: Timer?

  var settings = SettingsStore.load() {
    didSet {
      SettingsStore.save(settings)
      reevaluate()
    }
  }

  /// Whether a privileged backend exists to disable clamshell sleep. Without
  /// one the setting is offered but inert, so the UI disables it and says why.
  var clamshellSupported: Bool { clamshell.isSupported }

  /// Mirrors `SMAppService`'s registration.
  ///
  /// Stored rather than computed: `@Observable` cannot track a computed
  /// property, so a toggle bound to one would not reliably reflect changes —
  /// and every view update would fire an XPC call to the service-management
  /// daemon. The user can change this in System Settings behind our back, so
  /// `refreshLaunchAtLogin()` re-reads it whenever settings are shown.
  var launchAtLogin: Bool = LoginItem.isEnabled {
    didSet {
      guard launchAtLogin != oldValue else { return }
      do {
        try LoginItem.set(launchAtLogin)
        setupError = nil
      } catch {
        setupError = "Couldn't change the login item: \(error.localizedDescription)"
        // Put the switch back where the system actually is, rather than
        // leaving it showing a state that never took.
        launchAtLogin = oldValue
      }
    }
  }

  /// Re-read the system's view of the login item. Cheap enough to call when
  /// the settings window opens, too expensive to call on every render.
  func refreshLaunchAtLogin() {
    let actual = LoginItem.isEnabled
    if actual != launchAtLogin { launchAtLogin = actual }
  }

  var manualOverride = false {
    didSet { reevaluate() }
  }

  private(set) var pausedUntil: Date?

  /// Which agents are wired up to report to us. Until at least one is, Vigil
  /// can only be driven by the manual toggle.
  private(set) var installedAgents: Set<AgentKind> = []

  var hooksInstalled: Bool { !installedAgents.isEmpty }

  func isInstalled(_ integration: AgentIntegration) -> Bool {
    installedAgents.contains(integration.id)
  }

  /// Only the agents actually present on this machine are worth offering —
  /// a settings row for a tool someone has never installed is noise.
  var availableIntegrations: [AgentIntegration] {
    AgentIntegration.all.filter { integration in
      let home = FileManager.default.homeDirectoryForCurrentUser
      let dir = home.appendingPathComponent(integration.settingsPath).deletingLastPathComponent()
      return FileManager.default.fileExists(atPath: dir.path)
        || installedAgents.contains(integration.id)
    }
  }
  /// Surfaced in the panel rather than logged, so a failed setup is visible.
  private(set) var setupError: String?

  // MARK: - Collaborators

  private var store = SessionStore()
  private let assertion = PowerAssertion()
  private let clamshell = ClamshellController()
  private var bridge: EventBridge?
  private var tick: Timer?
  /// Previous snapshot, so we notify on transitions rather than on every tick.
  private var lastNotificationState: NotificationPolicy.State?

  // MARK: - Lifecycle

  func start() {
    // Undo any lid-close setting left behind by a previous run that died
    // before it could clean up, before doing anything else.
    clamshell.installSignalHandlers()
    Task { await clamshell.restoreOnLaunch() }

    bridge = EventBridge { [weak self] event in self?.handle(event) }
    bridge?.start()
    refreshInstalledAgents()

    tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.reevaluate() }
    }
    reevaluate()
  }

  func stop() {
    clock?.invalidate()
    tick?.invalidate()
    bridge?.stop()
    assertion.release()
    clamshell.restoreOnExit()
  }

  // MARK: - Actions

  /// Start and stop the display clock with the panel, not with the app.
  func panelBecameVisible() {
    now = Date()
    clock?.invalidate()
    clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.now = Date() }
    }
  }

  func panelBecameHidden() {
    clock?.invalidate()
    clock = nil
  }

  func handle(_ event: AgentEvent) {
    store.apply(event)
    reevaluate()
  }

  func pause(for duration: TimeInterval) {
    pausedUntil = Date().addingTimeInterval(duration)
    reevaluate()
  }

  func resume() {
    pausedUntil = nil
    reevaluate()
  }

  var isPaused: Bool {
    guard let until = pausedUntil else { return false }
    return until > Date()
  }

  func refreshInstalledAgents() {
    installedAgents = Set(
      AgentIntegration.all
        .filter { HookInstaller.live(for: $0).isInstalled }
        .map(\.id)
    )
  }

  /// Wire an agent up to report to us.
  func installHooks(for integration: AgentIntegration) {
    do {
      try HookInstaller.live(for: integration).install()
      installedAgents.insert(integration.id)
      setupError = nil
    } catch {
      setupError = error.localizedDescription
    }
  }

  func uninstallHooks(for integration: AgentIntegration) {
    do {
      try HookInstaller.live(for: integration).uninstall()
      installedAgents.remove(integration.id)
      setupError = nil
    } catch {
      setupError = error.localizedDescription
    }
  }

  /// Set up every agent present on this machine, in one action.
  func installAllAvailableHooks() {
    for integration in availableIntegrations where !isInstalled(integration) {
      installHooks(for: integration)
    }
  }

  // MARK: - The loop

  func reevaluate() {
    store.prune()

    // @Observable notifies on every assignment, equal or not, so guard each
    // one. Without this the panel re-renders every five seconds forever.
    let current = store.all()
    if current != sessions { sessions = current }

    let conditions = PowerMonitor.current()
    if conditions != power { power = conditions }

    decision = WakePolicy.decide(
      sessions: sessions,
      conditions: power,
      settings: settings,
      manualOverride: manualOverride,
      pausedUntil: pausedUntil
    )

    if decision.holdIdleAssertion {
      assertion.hold(reason: statusLine)
    } else {
      assertion.release()
    }

    Task { await clamshell.setSleepDisabled(decision.disableClamshellSleep) }

    // Everything holding the Mac awake except us — ours is already the
    // headline, and listing it twice would read as a bug.
    let others =
      PowerAssertion.systemAssertions()
      .filter { $0.preventsSystemSleep && $0.pid != ProcessInfo.processInfo.processIdentifier }
    if others != otherAssertions { otherAssertions = others }

    notifyIfWorthIt()
  }

  private func notifyIfWorthIt() {
    let current = NotificationPolicy.State(
      workingCount: workingCount,
      isHolding: decision.holdIdleAssertion,
      reason: decision.reason
    )
    defer { lastNotificationState = current }

    // No previous snapshot means this is the first tick after launch. Finding
    // agents already running is not a transition worth announcing.
    guard let previous = lastNotificationState,
      let event = NotificationPolicy.event(from: previous, to: current)
    else { return }

    switch event {
    case .allAgentsFinished(let count):
      Notifier.notify(.allAgentsFinished(count: count))
    case .guardrailStoppedHold:
      Notifier.notify(.guardrailStoppedHold(reason: statusLine))
    }
  }

  // MARK: - Presentation

  /// Plain-language status, in the user's terms rather than IOKit's. Shown in
  /// the panel and used as the assertion's own name, so `pmset -g assertions`
  /// explains itself too.
  var statusLine: String {
    switch decision.reason {
    case .agentsWorking(let count):
      "Awake - \(count) agent\(count == 1 ? "" : "s") working"
    case .manualOverride:
      "Awake - kept awake manually"
    case .paused(let until):
      "Paused until \(until.formatted(date: .omitted, time: .shortened))"
    case .noAgents:
      "No agents running - your Mac can sleep normally"
    case .batteryBelowFloor(let percent, let floor):
      "Sleeping - battery \(percent)% is below the \(floor)% floor"
    case .onBatteryAndPluggedInRequired:
      "Sleeping - set to run only on mains power"
    case .lowPowerMode:
      "Sleeping - Low Power Mode is on"
    case .tooHot(let state):
      state == .critical
        ? "Sleeping - your Mac is too hot to keep awake safely"
        : "Sleeping - your Mac is running hot"
    }
  }

  var workingCount: Int {
    sessions.filter { $0.state == .working }.count
  }
}
