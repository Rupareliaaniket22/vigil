import Foundation
import Testing

@testable import VigilCore

private func session(_ state: AgentState, id: String = "s1", ago: TimeInterval = 0) -> AgentSession
{
  var store = SessionStore()
  return store.apply(
    AgentEvent(agent: .claudeCode, sessionID: id, state: state),
    now: Timestamp.now.advanced(by: -ago)
  )
}

@Suite("WakePolicy")
struct WakePolicyTests {

  @Test("a working agent holds the Mac awake")
  func workingAgentHoldsWake() {
    let d = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(),
      settings: WakeSettings()
    )
    #expect(d.holdIdleAssertion)
    #expect(d.reason == .agentsWorking(count: 1))
  }

  @Test("no agents means the Mac may sleep")
  func noAgentsSleeps() {
    let d = WakePolicy.decide(
      sessions: [], conditions: PowerConditions(), settings: WakeSettings())
    #expect(!d.holdIdleAssertion)
    #expect(d.reason == .noAgents)
  }

  @Test("an agent waiting on the user does not hold the Mac awake")
  func waitingDoesNotHoldWake() {
    let d = WakePolicy.decide(
      sessions: [session(.waiting)], conditions: PowerConditions(), settings: WakeSettings())
    #expect(!d.holdIdleAssertion)
  }

  @Test("battery floor overrides active agents")
  func batteryFloorWins() {
    let d = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(batteryPercent: 12, isPluggedIn: false),
      settings: WakeSettings(batteryFloorPercent: 20)
    )
    #expect(!d.holdIdleAssertion)
    #expect(d.reason == .batteryBelowFloor(percent: 12, floor: 20))
  }

  @Test("battery floor does not apply on mains power")
  func batteryFloorIgnoredWhenPluggedIn() {
    let d = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(batteryPercent: 3, isPluggedIn: true),
      settings: WakeSettings(batteryFloorPercent: 20)
    )
    #expect(d.holdIdleAssertion)
  }

  @Test("battery floor overrides even a manual override")
  func guardrailsBeatManualOverride() {
    let d = WakePolicy.decide(
      sessions: [],
      conditions: PowerConditions(batteryPercent: 5, isPluggedIn: false),
      settings: WakeSettings(batteryFloorPercent: 20),
      manualOverride: true
    )
    #expect(!d.holdIdleAssertion)
  }

  @Test("only-when-plugged-in refuses battery power outright")
  func onlyWhenPluggedIn() {
    let d = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(batteryPercent: 100, isPluggedIn: false),
      settings: WakeSettings(onlyWhenPluggedIn: true)
    )
    #expect(!d.holdIdleAssertion)
    #expect(d.reason == .onBatteryAndPluggedInRequired)
  }

  @Test("Low Power Mode is respected on battery, ignored on mains")
  func lowPowerMode() {
    let onBattery = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(isPluggedIn: false, isLowPowerMode: true),
      settings: WakeSettings(respectLowPowerMode: true)
    )
    #expect(!onBattery.holdIdleAssertion)

    let onMains = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(isPluggedIn: true, isLowPowerMode: true),
      settings: WakeSettings(respectLowPowerMode: true)
    )
    #expect(onMains.holdIdleAssertion)
  }

  @Test("an active pause suppresses the hold until it expires")
  func pauseSuppressesWake() {
    let now = Date()
    let paused = WakePolicy.decide(
      sessions: [session(.working)], conditions: PowerConditions(), settings: WakeSettings(),
      pausedUntil: now.addingTimeInterval(600), now: now)
    #expect(!paused.holdIdleAssertion)

    let expired = WakePolicy.decide(
      sessions: [session(.working)], conditions: PowerConditions(), settings: WakeSettings(),
      pausedUntil: now.addingTimeInterval(-1), now: now)
    #expect(expired.holdIdleAssertion)
  }

  @Test("clamshell is never disabled unless we are also holding an idle assertion")
  func clamshellRequiresWakeHold() {
    let sleeping = WakePolicy.decide(
      sessions: [], conditions: PowerConditions(),
      settings: WakeSettings(allowClamshell: true))
    #expect(!sleeping.disableClamshellSleep)

    let awake = WakePolicy.decide(
      sessions: [session(.working)], conditions: PowerConditions(),
      settings: WakeSettings(allowClamshell: true))
    #expect(awake.disableClamshellSleep)
  }

  @Test("clamshell stays off when the user has not opted in")
  func clamshellOptIn() {
    let d = WakePolicy.decide(
      sessions: [session(.working)], conditions: PowerConditions(),
      settings: WakeSettings(allowClamshell: false))
    #expect(d.holdIdleAssertion)
    #expect(!d.disableClamshellSleep)
  }
}

@Suite("Thermal guardrail")
struct ThermalGuardrailTests {

  @Test("releases the hold when the machine gets hot")
  func releasesWhenHot() {
    let d = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(thermalState: .serious),
      settings: WakeSettings()
    )
    #expect(!d.holdIdleAssertion)
    #expect(d.reason == .tooHot(state: .serious))
  }

  @Test("heat outranks mains power")
  func heatAppliesOnMains() {
    // The hottest case there is: plugged in, working hard, lid shut, in a bag.
    let d = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(
        batteryPercent: 100, isPluggedIn: true, thermalState: .critical),
      settings: WakeSettings(allowClamshell: true)
    )
    #expect(!d.holdIdleAssertion)
    #expect(!d.disableClamshellSleep)
  }

  @Test("heat outranks a manual override")
  func heatBeatsManualOverride() {
    let d = WakePolicy.decide(
      sessions: [],
      conditions: PowerConditions(thermalState: .critical),
      settings: WakeSettings(),
      manualOverride: true
    )
    #expect(!d.holdIdleAssertion)
  }

  @Test("warm but below the ceiling still holds")
  func fairIsFine() {
    let d = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(thermalState: .fair),
      settings: WakeSettings(thermalCeiling: .serious)
    )
    #expect(d.holdIdleAssertion)
  }

  @Test(
    "the ceiling is configurable",
    arguments: [
      (ThermalState.fair, ThermalState.fair, false),
      (ThermalState.fair, ThermalState.serious, true),
      (ThermalState.serious, ThermalState.critical, true),
      (ThermalState.critical, ThermalState.critical, false),
    ])
  func ceilingIsConfigurable(state: ThermalState, ceiling: ThermalState, shouldHold: Bool) {
    let d = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(thermalState: state),
      settings: WakeSettings(thermalCeiling: ceiling)
    )
    #expect(d.holdIdleAssertion == shouldHold)
  }

  @Test("thermal states order correctly")
  func statesOrder() {
    #expect(ThermalState.nominal < .fair)
    #expect(ThermalState.fair < .serious)
    #expect(ThermalState.serious < .critical)
  }
}

@Suite("Guardrail classification")
struct GuardrailClassificationTests {

  @Test(
    "safety rules are guardrails",
    arguments: [
      WakeReason.batteryBelowFloor(percent: 10, floor: 20),
      .onBatteryAndPluggedInRequired,
      .lowPowerMode,
      .tooHot(state: .serious),
    ])
  func safetyRulesAreGuardrails(reason: WakeReason) {
    #expect(reason.isGuardrail)
  }

  @Test(
    "ordinary states are not",
    arguments: [
      WakeReason.agentsWorking(count: 1),
      .manualOverride,
      .noAgents,
    ])
  func ordinaryStatesAreNot(reason: WakeReason) {
    #expect(!reason.isGuardrail)
  }

  @Test("finishing work is not a guardrail")
  func finishingIsNotAGuardrail() {
    // This distinction decides whether we actively put the Mac to sleep.
    // Getting it wrong either drains the battery or sleeps the machine while
    // someone is using it.
    let finished = WakePolicy.decide(
      sessions: [], conditions: PowerConditions(), settings: WakeSettings())
    #expect(!finished.holdIdleAssertion)
    #expect(!finished.reason.isGuardrail)

    let cutOff = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(batteryPercent: 5, isPluggedIn: false),
      settings: WakeSettings())
    #expect(!cutOff.holdIdleAssertion)
    #expect(cutOff.reason.isGuardrail)
  }

  @Test("a pause is the user's choice, not a safety cutoff")
  func pauseIsNotAGuardrail() {
    let now = Date()
    let paused = WakePolicy.decide(
      sessions: [session(.working)], conditions: PowerConditions(), settings: WakeSettings(),
      pausedUntil: now.addingTimeInterval(600), now: now)
    #expect(!paused.reason.isGuardrail)
  }
}

@Suite("Asking the Mac to sleep")
struct ImmediateSleepTests {

  /// Every case here goes through `decide` rather than assembling a decision by
  /// hand. Whether a Mac should be *asked* to sleep turns on what the decision
  /// took away, not only on what it says — and a hand-built decision can claim
  /// a pairing the policy would never produce, which is how this rule came to
  /// be wrong while its tests were green.
  private func asksForSleep(
    sessions: [AgentSession] = [session(.working)],
    conditions: PowerConditions,
    settings: WakeSettings = WakeSettings(allowClamshell: true),
    manualOverride: Bool = false,
    pausedUntil: Date? = nil
  ) -> Bool {
    let now = Date()
    let decision = WakePolicy.decide(
      sessions: sessions,
      conditions: conditions,
      settings: settings,
      manualOverride: manualOverride,
      pausedUntil: pausedUntil,
      now: now
    )
    return WakePolicy.shouldRequestImmediateSleep(decision: decision, conditions: conditions)
  }

  /// Lid shut, on battery, below the floor.
  private let cutOff = PowerConditions(
    batteryPercent: 10, isPluggedIn: false, lidIsClosed: true)

  @Test("a guardrail that takes away a lid-closed hold asks for sleep")
  func guardrailWithLidShut() {
    #expect(asksForSleep(conditions: cutOff))
  }

  @Test("the same guardrail with the lid OPEN does not")
  func guardrailWithLidOpen() {
    // Someone is sitting in front of the machine. Sleeping it mid-keystroke
    // reads as a crash and loses unsaved work.
    #expect(
      !asksForSleep(
        conditions: PowerConditions(batteryPercent: 10, isPluggedIn: false, lidIsClosed: false)))
  }

  @Test("a machine with no lid never gets asked")
  func desktopNeverSleeps() {
    #expect(
      !asksForSleep(conditions: PowerConditions(thermalState: .critical, lidIsClosed: nil)))
  }

  /// The failure this gate exists to prevent, in both directions.
  ///
  /// A closed lid does not mean nobody is there: a laptop on a stand driving an
  /// external display has its lid shut all day. With no agent running and
  /// nothing overridden, a battery floor or a thermal ceiling is a rule that
  /// stops nothing — we hold no assertion, we have not touched `SleepDisabled`,
  /// and whatever is keeping that Mac awake, it is not us. Asking anyway ran
  /// `pmset sleepnow` on someone's working machine every five seconds.
  @Test(
    "a guardrail with nothing to stop asks for nothing",
    arguments: [[], [session(.idle)], [session(.waiting)]])
  func guardrailWithNothingRunning(sessions: [AgentSession]) {
    #expect(!asksForSleep(sessions: sessions, conditions: cutOff))
    #expect(
      !asksForSleep(
        sessions: sessions,
        conditions: PowerConditions(thermalState: .critical, lidIsClosed: true)))
  }

  @Test("nor when the user never asked for lid-closed operation")
  func neverWithoutClamshellOptIn() {
    // The setting is off, so we have never disabled clamshell sleep. This Mac
    // went to sleep when its lid shut, or it is awake for a reason that is not
    // ours to override.
    #expect(!asksForSleep(conditions: cutOff, settings: WakeSettings(allowClamshell: false)))
  }

  @Test("a guardrail cutting off a manual hold still asks")
  func manualHoldCutOff() {
    #expect(asksForSleep(sessions: [], conditions: cutOff, manualOverride: true))
  }

  @Test("a guardrail during a pause asks for nothing")
  func guardrailDuringPause() {
    // The pause had already released the hold. The guardrail arrived to find
    // nothing to take.
    #expect(
      !asksForSleep(conditions: cutOff, pausedUntil: Date().addingTimeInterval(600)))
  }

  @Test("work simply finishing does not ask for sleep")
  func finishingDoesNotSleep() {
    #expect(!asksForSleep(sessions: [], conditions: PowerConditions(lidIsClosed: true)))
  }

  @Test("a pause does not ask for sleep")
  func pauseDoesNotSleep() {
    #expect(
      !asksForSleep(
        conditions: PowerConditions(lidIsClosed: true),
        pausedUntil: Date().addingTimeInterval(600)))
  }

  @Test("we never ask for sleep while still holding the lid open ourselves")
  func neverWhileClamshellActive() {
    #expect(!asksForSleep(conditions: PowerConditions(lidIsClosed: true)))
  }
}

/// The whole decision space, swept rather than sampled.
///
/// The suites above test the cases someone thought of. This one enumerates
/// every combination of every input the policy reads — 230,400 of them — and
/// checks the properties that have to hold across all of it. The reason it
/// exists: "guardrails are evaluated before intent" is a claim about every
/// combination, and a handful of examples cannot say whether it is true.
///
/// Failures are collected rather than expected one at a time, so a break
/// reports how wide it is instead of stopping at the first of a quarter of a
/// million.
@Suite("Every decision path")
struct DecisionMatrixTests {

  /// Whether a safety rule applies, stated independently of `WakePolicy`.
  ///
  /// Deliberately a second expression of the rules rather than a call into the
  /// first: if the two ever disagree, one of them is wrong, and a test that
  /// asked the policy what the policy thinks could not tell.
  private func guardrailApplies(_ c: PowerConditions, _ s: WakeSettings) -> Bool {
    if c.thermalState >= s.thermalCeiling { return true }
    guard !c.isPluggedIn else { return false }
    return s.onlyWhenPluggedIn
      || c.batteryPercent < s.batteryFloorPercent
      || (s.respectLowPowerMode && c.isLowPowerMode)
  }

  @Test("every combination of every input obeys the same six rules")
  func sweep() {
    let now = Date()
    let soon = now.addingTimeInterval(600)
    let past = now.addingTimeInterval(-1)

    let intents: [(label: String, sessions: [AgentSession], manual: Bool, paused: Date?)] = [
      ("nothing running", [], false, nil),
      ("one working", [session(.working)], false, nil),
      ("two working", [session(.working, id: "a"), session(.working, id: "b")], false, nil),
      (
        "a mixture",
        [session(.working, id: "a"), session(.waiting, id: "b"), session(.idle, id: "c")], false,
        nil
      ),
      ("waiting and idle only", [session(.waiting, id: "a"), session(.idle, id: "b")], false, nil),
      ("manual override, nothing running", [], true, nil),
      ("manual override while working", [session(.working)], true, nil),
      ("paused while working", [session(.working)], false, soon),
      ("an expired pause while working", [session(.working)], false, past),
      ("paused, overridden and working at once", [session(.working)], true, soon),
    ]

    var failures: [String] = []
    var checked = 0

    for percent in [0, 19, 20, 21, 100] {
      for floor in [0, 20, 100] {
        for isPluggedIn in [true, false] {
          for isLowPowerMode in [true, false] {
            for respectLowPowerMode in [true, false] {
              for onlyWhenPluggedIn in [true, false] {
                for thermal in ThermalState.allCases {
                  for ceiling in ThermalState.allCases {
                    for lid in [nil, false, true] as [Bool?] {
                      for allowClamshell in [true, false] {
                        let conditions = PowerConditions(
                          batteryPercent: percent,
                          isPluggedIn: isPluggedIn,
                          isLowPowerMode: isLowPowerMode,
                          thermalState: thermal,
                          lidIsClosed: lid
                        )
                        let settings = WakeSettings(
                          batteryFloorPercent: floor,
                          onlyWhenPluggedIn: onlyWhenPluggedIn,
                          respectLowPowerMode: respectLowPowerMode,
                          allowClamshell: allowClamshell,
                          thermalCeiling: ceiling
                        )
                        let guarded = guardrailApplies(conditions, settings)

                        for intent in intents {
                          checked += 1
                          let d = WakePolicy.decide(
                            sessions: intent.sessions,
                            conditions: conditions,
                            settings: settings,
                            manualOverride: intent.manual,
                            pausedUntil: intent.paused,
                            now: now
                          )
                          let working = intent.sessions.filter { $0.state == .working }.count
                          let isPaused = intent.paused.map { $0 > now } ?? false
                          let wouldHold = !isPaused && (intent.manual || working > 0)

                          func fail(_ what: String) {
                            failures.append(
                              """
                              \(what)
                                  \(intent.label); battery \(percent)% floor \(floor)% \
                              \(isPluggedIn ? "on mains" : "on battery")\
                              \(isLowPowerMode ? ", LPM on" : "")\
                              \(respectLowPowerMode ? ", LPM respected" : "")\
                              \(onlyWhenPluggedIn ? ", mains only" : ""), \
                              thermal \(thermal) ceiling \(ceiling), \
                              lid \(lid.map(String.init) ?? "absent")\
                              \(allowClamshell ? ", clamshell allowed" : "")
                                  got \(d)
                              """)
                          }

                          // 1. The decision and its reason can never disagree.
                          if d.holdIdleAssertion != d.reason.holdsWake {
                            fail("holdIdleAssertion contradicts the reason it gives")
                          }
                          // 2. A guardrail applies exactly when one is reported.
                          if d.reason.isGuardrail != guarded {
                            fail(
                              guarded
                                ? "a guardrail applies but the reason is not one"
                                : "a guardrail was reported with none applying")
                          }
                          // 3. Lid-closed is an escalation of a hold, never its own thing.
                          if d.disableClamshellSleep != (d.holdIdleAssertion && allowClamshell) {
                            fail("clamshell sleep was disabled without an idle hold behind it")
                          }
                          // 4. Intent, in order, once no guardrail applies.
                          if !guarded {
                            let expected: WakeReason =
                              isPaused
                              ? .paused(until: intent.paused!)
                              : intent.manual
                                ? .manualOverride
                                : working > 0 ? .agentsWorking(count: working) : .noAgents
                            if d.reason != expected { fail("expected \(expected)") }
                          }
                          // 5. A guardrail always wins, whatever the intent.
                          if guarded && d.holdIdleAssertion {
                            fail("held the Mac awake with a guardrail applying")
                          }
                          // 6. We ask a Mac to sleep only where a guardrail has
                          //    taken away a lid-closed hold we would otherwise
                          //    have on it — never merely because one applies.
                          let asks = WakePolicy.shouldRequestImmediateSleep(
                            decision: d, conditions: conditions)
                          if asks != (lid == true && guarded && wouldHold && allowClamshell) {
                            fail("asked for immediate sleep at the wrong moment")
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    #expect(checked == 230_400, "the sweep shrank; it is only worth what it covers")
    #expect(
      failures.isEmpty,
      """
      \(failures.count) of \(checked) combinations disagreed. First few:
      \(failures.prefix(4).joined(separator: "\n"))
      """)
  }

  /// Which rule gets named when several apply at once.
  ///
  /// Not arbitrary: the reason is shown verbatim to someone asking why their
  /// run stopped, and only one of them can be.
  @Test(
    "the most dangerous applicable guardrail is the one reported",
    arguments: [
      // Heat outranks everything, including on mains, where no other rule looks.
      (
        PowerConditions(
          batteryPercent: 2, isPluggedIn: false, isLowPowerMode: true, thermalState: .critical),
        WakeSettings(batteryFloorPercent: 20, onlyWhenPluggedIn: true),
        WakeReason.tooHot(state: .critical)
      ),
      // Then the user's own flat refusal to run on battery at all.
      (
        PowerConditions(batteryPercent: 2, isPluggedIn: false, isLowPowerMode: true),
        WakeSettings(batteryFloorPercent: 20, onlyWhenPluggedIn: true),
        .onBatteryAndPluggedInRequired
      ),
      // Then the floor, which names a number.
      (
        PowerConditions(batteryPercent: 2, isPluggedIn: false, isLowPowerMode: true),
        WakeSettings(batteryFloorPercent: 20),
        .batteryBelowFloor(percent: 2, floor: 20)
      ),
      // Low Power Mode last: it is a preference, not a limit.
      (
        PowerConditions(batteryPercent: 99, isPluggedIn: false, isLowPowerMode: true),
        WakeSettings(batteryFloorPercent: 20),
        .lowPowerMode
      ),
    ])
  func guardrailPrecedence(
    conditions: PowerConditions, settings: WakeSettings, expected: WakeReason
  ) {
    let d = WakePolicy.decide(
      sessions: [session(.working)], conditions: conditions, settings: settings,
      manualOverride: true, pausedUntil: Date().addingTimeInterval(600))
    #expect(d.reason == expected)
    #expect(!d.holdIdleAssertion)
  }

  @Test("the floor is a floor: exactly at it still holds")
  func floorIsInclusive() {
    for (percent, holds) in [(19, false), (20, true), (21, true)] {
      let d = WakePolicy.decide(
        sessions: [session(.working)],
        conditions: PowerConditions(batteryPercent: percent, isPluggedIn: false),
        settings: WakeSettings(batteryFloorPercent: 20))
      #expect(d.holdIdleAssertion == holds, "at \(percent)% against a 20% floor")
    }
  }

  @Test("the order sessions arrive in cannot change the answer")
  func orderIndependence() {
    let sessions = [
      session(.working, id: "a"), session(.idle, id: "b"), session(.waiting, id: "c"),
      session(.working, id: "d"),
    ]
    let expected = WakePolicy.decide(
      sessions: sessions, conditions: PowerConditions(), settings: WakeSettings())
    for shuffled in [sessions.reversed(), sessions.shuffled(), sessions.shuffled()] {
      let d = WakePolicy.decide(
        sessions: Array(shuffled), conditions: PowerConditions(), settings: WakeSettings())
      #expect(d == expected)
    }
  }

  @Test("a pause that has already expired is no pause at all")
  func expiredPause() {
    let now = Date()
    let d = WakePolicy.decide(
      sessions: [session(.working)], conditions: PowerConditions(), settings: WakeSettings(),
      pausedUntil: now, now: now)
    // Exactly at the boundary: `until > now` is false, so the pause is over.
    #expect(d.reason == .agentsWorking(count: 1))
  }
}

@Suite("Lid-closed engages when asked")
struct ClamshellEngagementTests {

  @Test("enabling the setting engages it while an agent works")
  func engagesWhenWorking() {
    let d = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: PowerConditions(),
      settings: WakeSettings(allowClamshell: true))
    #expect(d.holdIdleAssertion)
    #expect(d.disableClamshellSleep, "the setting was on and an agent is working")
  }

  @Test("a manual hold engages it too")
  func engagesOnManualHold() {
    let d = WakePolicy.decide(
      sessions: [],
      conditions: PowerConditions(),
      settings: WakeSettings(allowClamshell: true),
      manualOverride: true)
    #expect(d.disableClamshellSleep)
  }

  @Test("it disengages the moment the work stops")
  func disengagesWhenIdle() {
    let d = WakePolicy.decide(
      sessions: [session(.idle)],
      conditions: PowerConditions(),
      settings: WakeSettings(allowClamshell: true))
    #expect(!d.disableClamshellSleep)
  }

  @Test(
    "every guardrail disengages it",
    arguments: [
      PowerConditions(batteryPercent: 5, isPluggedIn: false),
      PowerConditions(isPluggedIn: false, isLowPowerMode: true),
      PowerConditions(thermalState: .critical),
    ])
  func guardrailsDisengage(conditions: PowerConditions) {
    let d = WakePolicy.decide(
      sessions: [session(.working)],
      conditions: conditions,
      settings: WakeSettings(allowClamshell: true))
    #expect(!d.disableClamshellSleep, "a guardrail must release the lid-closed hold")
  }
}

@Suite("Reading the machine's power state")
struct PowerReadingTests {

  @Test("a laptop reports its battery")
  func laptop() {
    let c = PowerConditions.reading(
      battery: .init(currentCapacity: 41, maxCapacity: 100, isOnACPower: false))
    #expect(c.batteryPercent == 41)
    #expect(!c.isPluggedIn)
    #expect(c.hasBattery)
  }

  /// The case this Mac cannot be put into, and the one the panel gets wrong
  /// most visibly: a full-looking meter that never moves is a decoration.
  @Test("a desktop has no battery, and is on mains by definition")
  func desktop() {
    let c = PowerConditions.reading(battery: nil)
    #expect(!c.hasBattery)
    #expect(c.isPluggedIn)
    #expect(c.batteryPercent == 100)
  }

  @Test("every power guardrail is a no-op on a desktop")
  func desktopGuardrails() {
    let c = PowerConditions.reading(battery: nil, isLowPowerMode: true)
    let d = WakePolicy.decide(
      sessions: [session(.working)], conditions: c,
      settings: WakeSettings(
        batteryFloorPercent: 100, onlyWhenPluggedIn: true, respectLowPowerMode: true))
    #expect(d.holdIdleAssertion, "a desktop has no battery to protect")
  }

  /// Heat is the one guardrail a desktop still needs.
  @Test("a desktop still gets too hot")
  func desktopThermal() {
    let c = PowerConditions.reading(battery: nil, thermalState: .critical)
    let d = WakePolicy.decide(
      sessions: [session(.working)], conditions: c, settings: WakeSettings())
    #expect(!d.holdIdleAssertion)
    #expect(d.reason == .tooHot(state: .critical))
  }

  /// Low Power Mode is a setting Apple silicon desktops have too. It was being
  /// dropped on the floor for them, so the panel could not have shown it even
  /// though the machine was in it.
  @Test("Low Power Mode is reported whether or not there is a battery")
  func lowPowerModeIsAlwaysReported() {
    #expect(PowerConditions.reading(battery: nil, isLowPowerMode: true).isLowPowerMode)
    #expect(
      PowerConditions.reading(
        battery: .init(currentCapacity: 50, maxCapacity: 100, isOnACPower: true),
        isLowPowerMode: true
      ).isLowPowerMode)
  }

  @Test(
    "a battery the SMC cannot answer for reads as full, not as flat",
    arguments: [
      PowerConditions.BatteryReading(currentCapacity: 0, maxCapacity: 0, isOnACPower: false),
      .init(currentCapacity: -1, maxCapacity: 100, isOnACPower: false),
      .init(currentCapacity: 50, maxCapacity: -1, isOnACPower: false),
    ])
  func unreadableBatteryFailsOpen(reading: PowerConditions.BatteryReading) {
    // The other way round, a machine that had not finished booting its battery
    // driver would refuse to hold the Mac awake for a run that was about to
    // start — and say it was because the battery was flat.
    #expect(reading.percent == 100)
  }

  @Test("a genuinely flat battery is still flat")
  func zeroPercent() {
    #expect(
      PowerConditions.BatteryReading(
        currentCapacity: 0, maxCapacity: 100, isOnACPower: false
      ).percent == 0)
  }

  @Test(
    "the percentage is clamped to something that can be shown",
    arguments: [
      (100, 100, 100), (50, 100, 50), (1, 3, 33), (2, 3, 67), (120, 100, 100),
      (Int.max, 1, 100),
    ])
  func percentIsClamped(capacity: Int, maximum: Int, expected: Int) {
    let reading = PowerConditions.BatteryReading(
      currentCapacity: capacity, maxCapacity: maximum, isOnACPower: false)
    #expect(reading.percent == expected)
    #expect((0...100).contains(reading.percent))
  }

  @Test("mains state comes from the battery's own power source state")
  func mainsState() {
    #expect(
      PowerConditions.reading(
        battery: .init(currentCapacity: 41, maxCapacity: 100, isOnACPower: true)
      ).isPluggedIn)
  }
}
