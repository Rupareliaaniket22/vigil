import Testing

@testable import VigilCore

private func state(working: Int, holding: Bool, reason: WakeReason) -> NotificationPolicy.State {
  NotificationPolicy.State(workingCount: working, isHolding: holding, reason: reason)
}

@Suite("Notification policy")
struct NotificationPolicyTests {

  @Test("announces when the last agent finishes")
  func announcesCompletion() {
    let event = NotificationPolicy.event(
      from: state(working: 2, holding: true, reason: .agentsWorking(count: 2)),
      to: state(working: 0, holding: false, reason: .noAgents))
    #expect(event == .allAgentsFinished(count: 2))
  }

  @Test("says nothing when some agents are still working")
  func silentOnPartialCompletion() {
    let event = NotificationPolicy.event(
      from: state(working: 3, holding: true, reason: .agentsWorking(count: 3)),
      to: state(working: 1, holding: true, reason: .agentsWorking(count: 1)))
    #expect(event == nil)
  }

  @Test("says nothing when an agent starts")
  func silentOnStart() {
    let event = NotificationPolicy.event(
      from: state(working: 0, holding: false, reason: .noAgents),
      to: state(working: 1, holding: true, reason: .agentsWorking(count: 1)))
    #expect(event == nil)
  }

  @Test("warns when a guardrail drops the hold mid-run")
  func warnsOnGuardrail() {
    let reason = WakeReason.batteryBelowFloor(percent: 18, floor: 20)
    let event = NotificationPolicy.event(
      from: state(working: 1, holding: true, reason: .agentsWorking(count: 1)),
      to: state(working: 1, holding: false, reason: reason))
    #expect(event == .guardrailStoppedHold(reason: reason))
  }

  @Test("a guardrail firing with nothing running is not worth saying")
  func silentGuardrailWhenIdle() {
    let event = NotificationPolicy.event(
      from: state(working: 0, holding: false, reason: .noAgents),
      to: state(working: 0, holding: false, reason: .batteryBelowFloor(percent: 18, floor: 20)))
    #expect(event == nil)
  }

  @Test("the at-risk warning wins when both could fire")
  func guardrailOutranksCompletion() {
    // Work stops in the same tick a guardrail cuts in, but one agent remains.
    let reason = WakeReason.lowPowerMode
    let event = NotificationPolicy.event(
      from: state(working: 2, holding: true, reason: .agentsWorking(count: 2)),
      to: state(working: 1, holding: false, reason: reason))
    #expect(event == .guardrailStoppedHold(reason: reason))
  }

  @Test("a steady state says nothing")
  func silentWhenNothingChanges() {
    let s = state(working: 1, holding: true, reason: .agentsWorking(count: 1))
    #expect(NotificationPolicy.event(from: s, to: s) == nil)
  }
}
