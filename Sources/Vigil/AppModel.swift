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

  var settings = WakeSettings() {
    didSet { reevaluate() }
  }

  var manualOverride = false {
    didSet { reevaluate() }
  }

  private(set) var pausedUntil: Date?

  // MARK: - Collaborators

  private var store = SessionStore()
  private let assertion = PowerAssertion()
  private let clamshell = ClamshellController()
  private var bridge: EventBridge?
  private var tick: Timer?

  // MARK: - Lifecycle

  func start() {
    bridge = EventBridge { [weak self] event in self?.handle(event) }
    bridge?.start()

    tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.reevaluate() }
    }
    reevaluate()
  }

  func stop() {
    tick?.invalidate()
    bridge?.stop()
    assertion.release()
    clamshell.restoreOnExit()
  }

  // MARK: - Actions

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

  // MARK: - The loop

  func reevaluate() {
    store.prune()
    sessions = store.all()
    power = PowerMonitor.current()

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
    otherAssertions =
      PowerAssertion.systemAssertions()
      .filter { $0.preventsSystemSleep && $0.pid != ProcessInfo.processInfo.processIdentifier }
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
    }
  }

  var workingCount: Int {
    sessions.filter { $0.state == .working }.count
  }
}
