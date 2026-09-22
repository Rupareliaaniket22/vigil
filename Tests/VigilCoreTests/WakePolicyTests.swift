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
