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
  /// Only ticks while the panel is open. Reading the clock inside a row would
  /// freeze the moment SwiftUI stopped re-rendering, and re-rendering on a
  /// timer regardless of visibility is work a power utility has no business
  /// doing when nobody is looking.
  private(set) var now = Timestamp.now
  private var clock: Timer?

  /// Whether the panel is on screen.
  ///
  /// Gates the readings only the panel consumes. Sampling every assertion on
  /// the machine every five seconds with nothing displaying them contradicts
  /// the reason the display clock beside it is visibility-gated in the first
  /// place.
  private(set) var isPanelVisible = false

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

  /// When the pause ends, on the clock that cannot be adjusted.
  ///
  /// Monotonic rather than wall-clock for the same reason session staleness is.
  /// A pause is set now and tested later, and `Date` moves in between: an NTP
  /// step backwards — which a laptop takes within seconds of waking from a
  /// week asleep — would push the deadline further away by the size of the
  /// step, quietly turning a ten-minute pause into an hour of not holding the
  /// Mac awake while agents worked.
  private(set) var pauseDeadline: Timestamp?

  /// The same moment on the user's own clock, for "Paused until 5:30 PM".
  ///
  /// Computed rather than stored, so there is one deadline and no second copy
  /// to drift. Observation still works: reading this reads `pauseDeadline`,
  /// and that is the access `@Observable` records. (The stored-not-computed
  /// rule elsewhere in this file is about properties that answer from the
  /// filesystem, which `@Observable` genuinely cannot see change.)
  var pausedUntil: Date? { pauseDeadline?.wall }

  /// Which agents are wired up to report to us. Until at least one is, Vigil
  /// can only be driven by the manual toggle.
  private(set) var installedAgents: Set<AgentKind> = []

  /// Only the agents actually present on this machine are worth offering —
  /// a settings row for a tool someone has never installed is noise.
  ///
  /// Stored, not computed: it answers from the filesystem, so a computed
  /// version ran four `stat` calls every time SwiftUI evaluated a body, and
  /// `@Observable` could not see it change anyway.
  private(set) var availableIntegrations: [AgentIntegration] = []

  /// What each agent's settings file says about our hooks. Read from disk by
  /// `refreshInstalledAgents`, not on every render.
  private(set) var setupStates: [AgentKind: HookSetupState] = [:]

  /// Whether each host will actually run the hooks we installed.
  ///
  /// Separate from `setupStates` because it answers a different question.
  /// `setupStates` reads our own file and says the entries are present;
  /// this reads the host's trust record and says whether the host will honour
  /// them. Codex is the only one that gates, and it fails closed and silently.
  private(set) var trustStates: [AgentKind: HookTrustState] = [:]

  /// A sentence for when a host is holding our hooks at arm's length.
  ///
  /// Settings prints it under the rows. The panel puts it on the hover behind
  /// a shorter line of its own, because this one names a command inside
  /// another program and DESIGN.md keeps that vocabulary off the panel.
  func trustNotice(for integration: AgentIntegration) -> String? {
    (trustStates[integration.id] ?? .notRequired).explanation(host: integration.displayName)
  }

  /// Exactly what one press of "Trust" would record, held while it is read.
  ///
  /// State on the model rather than a flag in a row, because it is not a
  /// presentation detail: the records are captured at the moment they are put
  /// in front of the user and carried through to the write, so that what the
  /// confirmation names is what lands in the file. Anything that re-derived
  /// them on the way out would be a consent dialog describing one thing and
  /// approving another.
  private(set) var pendingTrustApproval: TrustApproval?

  /// One host's hooks, as a sentence somebody can decide on.
  struct TrustApproval: Equatable, Identifiable {
    let integration: AgentIntegration
    /// Approved verbatim. Nothing between here and disk recomputes them.
    let records: [CodexTrustWriter.Record]
    /// The command being approved, written the way the user knows it.
    let command: String
    /// The file the approval is written into.
    let configPath: String

    var id: AgentKind { integration.id }
    var host: String { integration.displayName }
    var events: [String] { records.map(\.event) }

    var title: String { "Let \(host) run Vigil's hooks?" }

    /// What will run, and when. The command leads: approving a hook is a
    /// statement about a command, and a dialog that named only the file would
    /// be asking for consent to the paperwork.
    var summary: String {
      "\(host) will run \(command) on \(Self.list(events))."
    }

    /// What the press does to the file, and what it leaves alone.
    var consequence: String {
      "Approving writes one trust record per event into \(configPath). "
        + "Nothing else in that file changes."
    }

    /// The two together, as the confirmation shows them.
    ///
    /// Assembled here rather than in the view so that a `String` reaches
    /// `Text` — interpolating into it there would resolve to the
    /// `LocalizedStringKey` overload and send a sentence built at runtime
    /// through a lookup table, which is not what any other line in this app
    /// does with text it has just composed.
    var message: String { summary + "\n\n" + consequence }

    /// "A, B and C", no Oxford comma — the house style everywhere else.
    private static func list(_ items: [String]) -> String {
      guard let last = items.last else { return "" }
      guard items.count > 1 else { return last }
      return items.dropLast().joined(separator: ", ") + " and " + last
    }
  }

  func isInstalled(_ integration: AgentIntegration) -> Bool {
    installedAgents.contains(integration.id)
  }

  /// Ready, out of date, or never set up.
  func setupState(for integration: AgentIntegration) -> HookSetupState {
    setupStates[integration.id] ?? .notSetUp
  }

  /// Surfaced in the panel rather than logged, so a failed setup is visible.
  private(set) var setupError: String?

  /// Set when the installed root helper does not match the one in this bundle.
  ///
  /// Refreshed on the loop but measured at most once per install: hashing two
  /// files every five seconds is not a thing a power utility should do.
  private(set) var helperNotice: String?

  /// Hosts that have stopped sending the event that ends a turn.
  ///
  /// Derived rather than stored — it is read only while the panel is open, and
  /// the verdict depends on the clock.
  var hookHealthWarnings: [String] {
    let now = Timestamp.now
    return hookHealth.suspectAgents(now: now).compactMap { hookHealth.warning(for: $0, now: now) }
  }

  /// Why agent events are not arriving, when they are not.
  private(set) var bridgeError: String?

  /// Set when another app already owns the global shortcut.
  private(set) var shortcutUnavailable = false

  func noteShortcutUnavailable() { shortcutUnavailable = true }

  // MARK: - Collaborators

  private var store = SessionStore()
  /// Watches what `prune` throws away, so a host that stops sending its idle
  /// event shows up as a warning rather than as a Mac that never sleeps.
  private var hookHealth = HookHealth()
  private let assertion = PowerAssertion()
  private let clamshell = ClamshellController()
  private var bridge: EventBridge?
  private var tick: Timer?
  /// Everything the notification rules remember between ticks — the previous
  /// snapshot, what each session was doing, how this run has been going, and
  /// which guardrail has already been warned about. All of it in `VigilCore`,
  /// where it can be walked through a whole run in a test.
  private var watch = NotificationPolicy.Watch()

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
    refreshInstalledAgents()
    bridge?.start()

    let tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.reevaluate() }
    }
    // Nothing here needs to land on the second. Tolerance lets macOS fire this
    // alongside a wakeup it was making anyway, which is the whole argument a
    // power utility has to make about its own cost.
    tick.tolerance = 1
    self.tick = tick
    reevaluate()
  }

  func stop() {
    clock?.invalidate()
    tick?.invalidate()
    bridge?.stop()
    assertion.release()
    clamshell.restoreOnExit()
  }

  /// Stand the bridge back up after it failed.
  ///
  /// Behind the panel's "Try again", because the usual causes — a stale socket
  /// from a run that was killed, a home directory that was not mounted yet —
  /// are gone by the time anyone reads the notice. `stop()` first: the failed
  /// task is still parked in `bridge`, and starting a second one would leave
  /// two servers racing for the same path.
  func retryBridge() {
    guard let bridge else { return }
    bridge.stop()
    bridgeError = nil
    bridge.start()
  }

  // MARK: - Actions

  /// Start and stop the display clock with the panel, not with the app.
  func panelBecameVisible() {
    isPanelVisible = true
    now = .now
    // Hooks can be changed on disk by an uninstall, an upgrade, or another
    // tool. Re-reading them when the panel opens is the cheapest cadence that
    // still means what the panel shows is true when someone looks at it.
    refreshInstalledAgents()
    clock?.invalidate()
    let clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.now = .now }
    }
    // Elapsed times are rendered to the minute, so letting macOS coalesce this
    // with other work costs nothing and saves a wakeup.
    clock.tolerance = 5
    self.clock = clock

    // Last, so the readings the panel is about to show — the assertion ledger
    // above all — are taken with the panel already counted as visible.
    reevaluate()
  }

  func panelBecameHidden() {
    isPanelVisible = false
    clock?.invalidate()
    clock = nil
  }

  func handle(_ event: AgentEvent) {
    store.apply(event)
    reevaluate()
  }

  /// Put sample sessions in front of the panel, and nothing else.
  ///
  /// The headless layout check runs as the real bundled app, so it reads the
  /// real settings and can reach the real helper. Routing its sample sessions
  /// through `handle` would have taken a power assertion and, for anyone with
  /// lid-closed support turned on, cleared `SleepDisabled` and then exited
  /// without restoring it — leaving the machine that built Vigil unable to
  /// sleep with the lid shut. Populate the view state; touch nothing.
  func loadSampleSessions(_ events: [AgentEvent]) {
    for event in events { store.apply(event) }
    sessions = store.all()
  }

  /// Put sample ledger rows in front of the panel, and nothing else.
  ///
  /// Same rule as `loadSampleSessions`: the layout check runs as the real app,
  /// so it reads the real machine. It must not be the thing that copies every
  /// assertion on it out of the kernel, and it must not take one.
  func loadSampleAssertions(_ assertions: [SystemAssertion]) {
    otherAssertions = assertions
  }

  /// Put the settings window into the worst shape it can honestly be in, and
  /// nothing else.
  ///
  /// Same rule as `loadSampleSessions`: view state only, no side effects, no
  /// file touched. It exists because the layout check could otherwise only ever
  /// measure the machine it ran on — where `setupError` is nil by construction,
  /// so the one input that can grow without bound is the one input never
  /// exercised, and a window with a hard height and no scroll view was being
  /// checked against its easiest case. The panel has
  /// `MenuPanelDegradedGallery` for exactly this reason; this is the settings
  /// window's half of it.
  func loadWorstCaseSetup(
    trust: [AgentKind: HookTrustState],
    error: String,
    helperNotice: String,
    clamshellSupported: Bool
  ) {
    // Every integration offered, because four rows are taller than the
    // sentence that stands in for them when none is installed.
    availableIntegrations = AgentIntegration.all
    trustStates = trust
    setupStates = AgentIntegration.all.reduce(into: [:]) { states, integration in
      let state = trust[integration.id] ?? .notRequired
      states[integration.id] = state.isSatisfied ? .ready : .untrusted
    }
    installedAgents = Set(setupStates.filter { $0.value == .ready }.map(\.key))
    setupError = error
    self.helperNotice = helperNotice
    // Which of the two things the lid section can say is on screen. They are
    // mutually exclusive — a drifted helper is only worth warning about once
    // the sudoers rule that makes it usable exists, since otherwise turning
    // the switch on reinstalls it anyway — so the caller passes both in turn
    // and takes the taller, rather than this guessing which of them it is.
    self.clamshellSupported = clamshellSupported
  }

  func pause(for duration: TimeInterval) {
    pauseDeadline = Timestamp.now.advanced(by: duration)
    reevaluate()
  }

  func resume() {
    pauseDeadline = nil
    reevaluate()
  }

  var isPaused: Bool {
    guard let until = pauseDeadline else { return false }
    return Timestamp.now.isBefore(until)
  }

  /// What both install paths say when the file lands and the helper still
  /// cannot be reached. Named once so the two cannot drift into disagreeing
  /// about the same outcome.
  private static let helperInstalledButUnusable =
    "The helper installed but Vigil can't see it. Try quitting and reopening Vigil."

  /// Turn lid-closed support on or off, installing the privileged helper the
  /// first time if it isn't there yet.
  ///
  /// The setting is only stored once the helper actually exists — a switch that
  /// stays on while nothing can act on it is worse than one that refuses.
  func setLidClosed(_ enabled: Bool) {
    guard enabled else {
      settings.allowClamshell = false
      return
    }
    guard !clamshellSupported else {
      settings.allowClamshell = true
      return
    }

    do {
      try ClamshellInstaller.install()
      // The file HelperDrift hashed is the one we just replaced.
      HelperDrift.invalidate()
      clamshellSupported = clamshell.isSupported
      settings.allowClamshell = clamshellSupported
      setupError = clamshellSupported ? nil : Self.helperInstalledButUnusable
    } catch let error as ClamshellInstaller.InstallError {
      // A cancelled password prompt is a decision, not a fault.
      if case .cancelled = error {
        settings.allowClamshell = false
        return
      }
      settings.allowClamshell = false
      setupError = error.localizedDescription
    } catch {
      settings.allowClamshell = false
      setupError = error.localizedDescription
    }
  }

  /// Replace the installed lid-closed helper with the copy in this bundle.
  ///
  /// Separate from `setLidClosed`, which installs only when nothing is
  /// installed at all: a helper that is present and reachable but is not the
  /// one this build ships takes the `clamshellSupported` early return, so
  /// before this existed `helperNotice` named a remedy — "reinstall lid-closed
  /// support" — that no control in the app performed.
  ///
  /// Leaves `settings.allowClamshell` alone on purpose. This replaces a file;
  /// whether the user wants the feature on is a separate answer they have
  /// already given, and a reinstall that also flipped their switch would be
  /// this window changing a setting nobody touched.
  func reinstallClamshellHelper() {
    do {
      try ClamshellInstaller.install()
      // The file `HelperDrift` hashed is the one we just replaced.
      HelperDrift.invalidate()
      clamshellSupported = clamshell.isSupported
      // The same answer its sibling gives, and the same sentence. An install
      // that succeeds and leaves the helper unreachable is exactly as useless
      // here as it is there, and reporting it as a clean reinstall sent the
      // user back to a switch that still would not work, with nothing on
      // screen admitting it.
      setupError = clamshellSupported ? nil : Self.helperInstalledButUnusable
    } catch let error as ClamshellInstaller.InstallError {
      // A cancelled password prompt is a decision, not a fault.
      if case .cancelled = error { return }
      setupError = error.localizedDescription
    } catch {
      setupError = error.localizedDescription
    }
    // Re-reads the drift verdict through the loop, so the notice clears itself
    // rather than waiting for the next tick.
    reevaluate()
  }

  func refreshInstalledAgents() {
    var states: [AgentKind: HookSetupState] = [:]
    var trusts: [AgentKind: HookTrustState] = [:]
    for integration in AgentIntegration.all {
      // One installer per integration: each accessor below re-reads the file,
      // and there are three of them now.
      let installer = HookInstaller.live(for: integration)
      let trust = installer.trustState
      trusts[integration.id] = trust
      states[integration.id] = HookConfiguration.setupState(
        missingEvents: installer.missingEvents,
        expectedEvents: integration.allEvents,
        retiredEvents: installer.retiredEvents,
        trust: trust
      )
    }
    if states != setupStates { setupStates = states }
    if trusts != trustStates { trustStates = trusts }

    let installed = Set(states.filter { $0.value == .ready }.map(\.key))
    if installed != installedAgents { installedAgents = installed }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let available = AgentIntegration.all.filter { integration in
      if states[integration.id] != .notSetUp { return true }
      let dir = home.appendingPathComponent(integration.settingsPath).deletingLastPathComponent()
      return FileManager.default.fileExists(atPath: dir.path)
    }
    if available.map(\.id) != availableIntegrations.map(\.id) {
      availableIntegrations = available
    }
  }

  /// Wire an agent up to report to us, or bring an older install up to date.
  func installHooks(for integration: AgentIntegration) {
    do {
      try HookInstaller.live(for: integration).install()
      setupError = nil
    } catch {
      setupError = error.localizedDescription
    }
    // Re-read rather than assume. An install that threw part-way, or one whose
    // script did not end up executable, must not leave the panel claiming the
    // agent is reporting when it is not.
    refreshInstalledAgents()
  }

  func uninstallHooks(for integration: AgentIntegration) {
    do {
      try HookInstaller.live(for: integration).uninstall()
      setupError = nil
    } catch {
      setupError = error.localizedDescription
    }
    refreshInstalledAgents()
  }

  /// Work out what the host would be told to trust, and put it in front of the
  /// user. Writes nothing.
  ///
  /// The two halves are separate calls on purpose. A single `trust()` that
  /// read the hooks and wrote the record in one press would be the thing this
  /// feature exists not to be — the competitor's silent self-approval with a
  /// button in front of it. Nothing reaches `config.toml` until someone has
  /// seen the command, the events and the file, and said yes to those.
  func reviewTrust(for integration: AgentIntegration) {
    let installer = HookInstaller.live(for: integration)
    do {
      let records = try installer.trustRecords()
      setupError = nil
      pendingTrustApproval = TrustApproval(
        integration: integration,
        records: records,
        // The installer's own script path, not a second lookup of the same
        // constant: the command shown has to be the command hashed.
        command: Self.underHome(installer.scriptPath),
        configPath: Self.underHome(HookInstaller.codexConfigFilePath)
      )
    } catch {
      pendingTrustApproval = nil
      setupError = error.localizedDescription
    }
  }

  /// The user read it and closed it without approving. Nothing happened.
  func cancelTrustReview() {
    pendingTrustApproval = nil
  }

  /// Record the approval the user has just read.
  ///
  /// Takes the approval rather than reading `pendingTrustApproval`, because
  /// dismissing the confirmation and running its action are two events whose
  /// order SwiftUI does not promise — and the one ordering that loses the
  /// records would write nothing while the row went on saying "Not trusted".
  func trustHooks(for approval: TrustApproval) {
    pendingTrustApproval = nil
    do {
      try HookInstaller.live(for: approval.integration).recordTrust(approval.records)
      setupError = nil
    } catch {
      setupError = error.localizedDescription
    }
    // Re-read rather than assume, the same as `installHooks`: the row must not
    // claim the host is running our hooks until the host's own file says so.
    refreshInstalledAgents()
  }

  // MARK: - The loop

  func reevaluate() {
    // One reading of the clock for the whole pass. Pruning, staleness and the
    // notification rules all measure against it, and three readings taken a few
    // microseconds apart are three chances for them to disagree about which
    // side of a deadline this tick is on.
    let now = Timestamp.now
    // Kept, not discarded. A session pruned while it was still working is the
    // only evidence Vigil ever gets that it lost an agent rather than watching
    // one finish, and this line used to be where that evidence went.
    let expired = store.prune(now: now)
    hookHealth.record(expired: expired, now: now)

    // @Observable notifies on every assignment, equal or not, so guard each
    // one. Without this the panel re-renders every five seconds forever.
    let current = store.all(now: now)
    if current != sessions { sessions = current }

    let conditions = PowerMonitor.current()
    if conditions != power { power = conditions }

    // Picks up an installer run without needing a restart.
    let supported = clamshell.isSupported
    if supported != clamshellSupported { clamshellSupported = supported }

    let notice = HelperDrift.notice
    if notice != helperNotice { helperNotice = notice }

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
      pausedUntil: pauseDeadline
    )

    if decision.holdIdleAssertion {
      // `assertionName`, never `statusLine`. `pmset -g assertions` prints this
      // through a context that is not UTF-8, where the em dash arrives as a
      // replacement character. The fold is structural now — there is no raw
      // string here to get wrong — which is the point, because this exact bug
      // has been fixed once and reintroduced twice.
      assertion.hold(reason: decision.reason.assertionName)
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
    //
    // Only while the panel is open. `IOPMCopyAssertionsByProcess` copies every
    // assertion on the machine out of the kernel, and the ledger is the only
    // thing that reads the result.
    if isPanelVisible {
      let others =
        PowerAssertion.systemAssertions()
        .filter { $0.preventsSystemSleep && $0.pid != ProcessInfo.processInfo.processIdentifier }
      if others != otherAssertions { otherAssertions = others }
    }

    notifyIfWorthIt(expired: expired, now: now)
  }

  /// Hand the whole tick to the policy and post whatever it decides to say.
  ///
  /// Everything this used to work out for itself — whether the run is over, how
  /// it ended, whether a guardrail was in force, which sound that makes — is
  /// now one call, because each of those questions was being answered here by
  /// `workingCount` reaching zero and four different things make that happen.
  private func notifyIfWorthIt(expired: [AgentSession], now: Timestamp) {
    guard
      let spoken = watch.observe(
        sessions: sessions,
        expired: expired,
        isHolding: decision.holdIdleAssertion,
        reason: decision.reason,
        completionSoundEnabled: SoundSettings.playsCompletionSound,
        now: now)
    else { return }

    switch spoken.event {
    case .allAgentsFinished(let count):
      Notifier.notify(.allAgentsFinished(count: count), sound: spoken.sound)
    case .runEndedBadly(let count):
      Notifier.notify(.runEndedBadly(count: count), sound: spoken.sound)
    case .lostContact(let count):
      Notifier.notify(.lostContact(count: count), sound: spoken.sound)
    case .guardrailStoppedHold:
      Notifier.notify(.guardrailStoppedHold(reason: statusLine), sound: spoken.sound)
    case .guardrailPreventedHold:
      Notifier.notify(.guardrailPreventedHold(reason: statusLine), sound: spoken.sound)
    }
  }

  // MARK: - Presentation

  // The wording lives on `WakeReason` in VigilCore, beside the decision it
  // describes, so it can be tested. These three are the whole app-layer view of
  // it: forwarding rather than re-deriving means there is exactly one place a
  // sentence can be changed, and no second copy to drift.

  var statusHeadline: String { decision.reason.statusHeadline }
  var statusDetail: String { decision.reason.statusDetail }

  /// One line, for the menu bar tooltip and for `Notifier`. Keeps the em dash:
  /// both of those render UTF-8. The power assertion deliberately does not use
  /// this — see `reevaluate`.
  var statusLine: String { decision.reason.statusLine }

  /// A path the way its owner knows it: `~` rather than `/Users/them`.
  ///
  /// Shared with the panel's project paths. A home directory spelled out in
  /// full is three components of noise in front of the one that carries the
  /// meaning, and in the trust confirmation it is the file name that has to be
  /// recognisable at a glance.
  static func underHome(_ path: String) -> String {
    guard !path.isEmpty else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

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

  /// The rows that follow the live sessions: the agents with nothing running.
  ///
  /// Strictly "no live sessions", so no agent can appear twice in a list whose
  /// two halves are now the same row. An agent that *is* running and still
  /// isn't wired up properly used to be forced in here for the sake of its Set
  /// up button; it is answered by `integrationsNeedingAttention` instead, in
  /// the section header, where one tap fixes all of them at once.
  var quietIntegrations: [AgentIntegration] {
    availableIntegrations.filter { sessions(for: $0).isEmpty }
  }

  /// Agents Vigil is hearing from but cannot hear properly.
  ///
  /// Either they were set up by an older version and send less than Vigil now
  /// listens for, or their hooks have gone from the settings file while a
  /// session is still live. Both look completely normal from the outside — a
  /// working row, a sensible elapsed time — while runs quietly fail to hold the
  /// Mac awake, so something has to say so. Agents with no sessions are absent
  /// on purpose: they have a row of their own, carrying its own button.
  /// `.untrusted` is deliberately not here, and the header is the reason.
  /// Everything in this list is fixed by `fixIntegrationsNeedingAttention`,
  /// which re-runs the install — and `HookConfiguration.setupState` returns
  /// `.untrusted` precisely when the install is complete and the host will not
  /// run it, so re-running it cannot change the state. Including it gave the
  /// header a button reading "Codex needs setting up" that was false, did
  /// nothing, and went on saying the same thing after every press.
  /// `untrustedIntegrations` carries that case instead.
  var integrationsNeedingAttention: [AgentIntegration] {
    availableIntegrations.filter {
      !sessions(for: $0).isEmpty
        && setupState(for: $0) != .ready
        && setupState(for: $0) != .untrusted
    }
  }

  /// Hosts that have our hooks and will not run them.
  ///
  /// Not filtered by whether anything is running: a host whose trust record
  /// went stale while a session was live keeps that session for the whole
  /// staleness window, so the one case where this matters most is the one case
  /// with no quiet row to hang a button on.
  var untrustedIntegrations: [AgentIntegration] {
    availableIntegrations.filter { setupState(for: $0) == .untrusted }
  }

  /// What the Agents header's trailing slot says, or nil when it says nothing.
  ///
  /// Replaces an 83pt banner that explained at length something the user can
  /// only do one thing about. The words split on which fix it is, because
  /// "updating" an agent that was never set up would be a lie, and a single
  /// vaguer word covering both would be worse than either.
  var attentionSummary: String? {
    let needy = integrationsNeedingAttention
    guard let first = needy.first else { return nil }
    let verb =
      needy.allSatisfy { setupState(for: $0) == .outOfDate }
      ? "updating" : "setting up"
    return needy.count == 1
      ? "\(first.displayName) needs \(verb)"
      : "\(needy.count) need \(verb)"
  }

  /// Bring every agent in `integrationsNeedingAttention` up to date.
  func fixIntegrationsNeedingAttention() {
    for integration in integrationsNeedingAttention { installHooks(for: integration) }
  }
}
