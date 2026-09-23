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

  /// Whether a privileged backend exists to disable clamshell sleep.
  ///
  /// Stored rather than computed: this depends on a file on disk that appears
  /// when the user runs the installer, and `@Observable` cannot track a
  /// computed property reading the filesystem — the toggle would have stayed
  /// greyed out after a successful install until something else forced a
  /// redraw. Refreshed on every evaluation, so it lights up on its own.
  private(set) var clamshellSupported = false

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

  /// Why agent events are not arriving, when they are not.
  private(set) var bridgeError: String?

  /// Set when another app already owns the global shortcut.
  private(set) var shortcutUnavailable = false

  func noteShortcutUnavailable() { shortcutUnavailable = true }

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

    bridge = EventBridge(
      onEvent: { [weak self] event in self?.handle(event) },
      onStatusChange: { [weak self] status in
        switch status {
        case .listening: self?.bridgeError = nil
        case .failed(let reason): self?.bridgeError = reason
        case .starting: break
        }
      }
    )
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

    // Picks up an installer run without needing a restart.
    let supported = clamshell.isSupported
    if supported != clamshellSupported { clamshellSupported = supported }

    // A setting the user enabled while the helper was missing must not stay
    // silently on once it becomes possible — and must not pretend to work
    // while it isn't.
    if settings.allowClamshell && !supported {
      Self.log.notice("lid-closed is enabled but no privileged helper is installed")
    }

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

    // A guardrail releasing the override with the lid shut must actively ask
    // for sleep. macOS only re-evaluates clamshell sleep on a lid event, so
    // merely clearing the flag would leave the Mac awake and draining — the
    // exact failure a battery floor exists to prevent.
    let forcedOff = WakePolicy.shouldRequestImmediateSleep(
      decision: decision, conditions: power)
    // Not wrapped in a Task: the controller is single-flight and records the
    // desired state synchronously, so calls can no longer interleave.
    clamshell.setSleepDisabled(decision.disableClamshellSleep, requestSleep: forcedOff)

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

  /// The headline. Deliberately short enough never to wrap in a 340pt panel —
  /// a two-line headline breaks the baseline everything beside it aligns to.
  var statusHeadline: String {
    decision.holdIdleAssertion ? "Keeping your Mac awake" : "Your Mac can sleep"
  }

  /// The reason, underneath. Splitting headline from detail means the panel
  /// always answers "what" first and "why" second, instead of one long
  /// sentence that has to wrap.
  var statusDetail: String {
    switch decision.reason {
    case .agentsWorking(let count):
      "\(count) agent\(count == 1 ? "" : "s") working"
    case .manualOverride:
      "Kept awake manually"
    case .paused(let until):
      "Paused until \(until.formatted(date: .omitted, time: .shortened))"
    case .noAgents:
      "No agents are running"
    case .batteryBelowFloor(let percent, let floor):
      "Battery \(percent)% is below your \(floor)% floor"
    case .onBatteryAndPluggedInRequired:
      "On battery - set to hold only while plugged in"
    case .lowPowerMode:
      "Low Power Mode is on"
    case .tooHot(let state):
      state == .critical ? "Your Mac is too hot to stay awake safely" : "Your Mac is running hot"
    }
  }

  /// One line, for the menu bar tooltip and the power assertion's own name, so
  /// `pmset -g assertions` explains itself too.
  var statusLine: String { "\(statusHeadline) - \(statusDetail)" }

  var workingCount: Int {
    sessions.filter { $0.state == .working }.count
  }

  /// Live sessions belonging to one agent.
  func sessions(for integration: AgentIntegration) -> [AgentSession] {
    sessions.filter { $0.agent == integration.id }
  }

  /// What to show beside an agent's name: how many sessions, or that it is idle.
  func summary(for integration: AgentIntegration) -> String {
    let mine = sessions(for: integration)
    let working = mine.filter { $0.state == .working }.count
    if working > 0 { return "\(working) working" }
    if !mine.isEmpty { return "\(mine.count) session\(mine.count == 1 ? "" : "s")" }
    return isInstalled(integration) ? "idle" : "not set up"
  }

  func isWorking(_ integration: AgentIntegration) -> Bool {
    sessions(for: integration).contains { $0.state == .working }
  }

  /// Agents with nothing live: either idle, or never wired up. Listed under
  /// the active sessions so the panel shows what is running first and what
  /// exists second.
  var quietIntegrations: [AgentIntegration] {
    availableIntegrations.filter { sessions(for: $0).isEmpty }
  }
}
