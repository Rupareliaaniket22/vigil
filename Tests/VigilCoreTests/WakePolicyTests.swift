import Foundation
import Testing

@testable import VigilCore

private func session(_ state: AgentState, id: String = "s1", ago: TimeInterval = 0) -> AgentSession
{
  var store = SessionStore()
  let now = Date()
  return store.apply(
    AgentEvent(agent: .claudeCode, sessionID: id, state: state),
    now: now.addingTimeInterval(-ago)
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

  private func decision(_ reason: WakeReason, clamshell: Bool = false) -> WakeDecision {
    WakeDecision(
      holdIdleAssertion: reason.holdsWake,
      disableClamshellSleep: clamshell,
      reason: reason)
  }

  @Test("a guardrail with the lid shut asks for sleep")
  func guardrailWithLidShut() {
    #expect(
      WakePolicy.shouldRequestImmediateSleep(
        decision: decision(.batteryBelowFloor(percent: 10, floor: 20)),
        conditions: PowerConditions(lidIsClosed: true)))
  }

  @Test("the same guardrail with the lid OPEN does not")
  func guardrailWithLidOpen() {
    // Someone is sitting in front of the machine. Sleeping it mid-keystroke
    // reads as a crash and loses unsaved work.
    #expect(
      !WakePolicy.shouldRequestImmediateSleep(
        decision: decision(.batteryBelowFloor(percent: 10, floor: 20)),
        conditions: PowerConditions(lidIsClosed: false)))
  }

  @Test("a machine with no lid never gets asked")
  func desktopNeverSleeps() {
    #expect(
      !WakePolicy.shouldRequestImmediateSleep(
        decision: decision(.tooHot(state: .critical)),
        conditions: PowerConditions(lidIsClosed: nil)))
  }

  @Test("work simply finishing does not ask for sleep")
  func finishingDoesNotSleep() {
    #expect(
      !WakePolicy.shouldRequestImmediateSleep(
        decision: decision(.noAgents),
        conditions: PowerConditions(lidIsClosed: true)))
  }

  @Test("a pause does not ask for sleep")
  func pauseDoesNotSleep() {
    #expect(
      !WakePolicy.shouldRequestImmediateSleep(
        decision: decision(.paused(until: Date().addingTimeInterval(600))),
        conditions: PowerConditions(lidIsClosed: true)))
  }

  @Test("we never ask for sleep while still holding the lid open ourselves")
  func neverWhileClamshellActive() {
    #expect(
      !WakePolicy.shouldRequestImmediateSleep(
        decision: decision(.agentsWorking(count: 1), clamshell: true),
        conditions: PowerConditions(lidIsClosed: true)))
  }
}
