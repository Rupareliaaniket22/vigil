import Foundation
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

@Suite("Notifications nobody asked for")
struct NotificationRestraintTests {

  /// The user pressed Pause, in this app, a second ago. Telling them their run
  /// "may not finish" — at time-sensitive priority, with a sound — reports
  /// their own decision back to them as if it were a fault.
  @Test("pausing does not raise the guardrail alarm")
  func pausingIsNotAGuardrail() {
    let event = NotificationPolicy.event(
      from: state(working: 2, holding: true, reason: .agentsWorking(count: 2)),
      to: state(working: 2, holding: false, reason: .paused(until: Date())))
    #expect(event == nil)
  }

  /// And the same for the guardrail that is a guardrail, so the fix above
  /// cannot be mistaken for "stop warning about anything".
  @Test(
    "every real guardrail still raises it",
    arguments: [
      WakeReason.batteryBelowFloor(percent: 18, floor: 20),
      .onBatteryAndPluggedInRequired,
      .lowPowerMode,
      .tooHot(state: .serious),
    ])
  func realGuardrailsStillWarn(reason: WakeReason) {
    let event = NotificationPolicy.event(
      from: state(working: 1, holding: true, reason: .agentsWorking(count: 1)),
      to: state(working: 1, holding: false, reason: reason))
    #expect(event == .guardrailStoppedHold(reason: reason))
  }

  /// The model re-evaluates every five seconds. A warning that repeated on
  /// every tick until the battery recovered would be worse than none.
  @Test("the guardrail warning fires once, not on every tick")
  func warnsOnlyOnTheTransition() {
    let working = state(working: 1, holding: true, reason: .agentsWorking(count: 1))
    let cut = state(working: 1, holding: false, reason: .lowPowerMode)
    #expect(NotificationPolicy.event(from: working, to: cut) != nil)
    #expect(NotificationPolicy.event(from: cut, to: cut) == nil)
    // Still nothing when one guardrail gives way to another.
    #expect(
      NotificationPolicy.event(
        from: cut, to: state(working: 1, holding: false, reason: .tooHot(state: .serious))) == nil)
  }

  /// Resuming is the ordinary way out of a pause and means nothing is wrong.
  @Test("resuming from a pause says nothing either")
  func resumingIsSilent() {
    let event = NotificationPolicy.event(
      from: state(working: 1, holding: false, reason: .paused(until: Date())),
      to: state(working: 1, holding: true, reason: .agentsWorking(count: 1)))
    #expect(event == nil)
  }

  /// A pause outliving the work still counts as the work finishing — that is
  /// what the user walked away waiting for, whatever the hold was doing.
  @Test("work finishing during a pause is still worth announcing")
  func finishingDuringAPause() {
    let event = NotificationPolicy.event(
      from: state(working: 2, holding: false, reason: .paused(until: Date())),
      to: state(working: 0, holding: false, reason: .paused(until: Date())))
    #expect(event == .allAgentsFinished(count: 2))
  }
}

@Suite("Notification copy")
struct NotificationCopyTests {

  /// The alert's title has already said the hold stopped; the body should not
  /// open by saying the opposite in the machine's own words.
  @Test("a status line is trimmed to its reason")
  func trimsTheHeadline() {
    #expect(
      NotificationPolicy.detail(
        inStatusLine: WakeReason.batteryBelowFloor(percent: 18, floor: 20).statusLine)
        == "Battery 18%, below the 20% you set")
  }

  /// One reason carries a second em dash, and it is the half worth keeping.
  @Test("only the first separator is a separator")
  func splitsOnce() {
    #expect(
      NotificationPolicy.detail(inStatusLine: WakeReason.onBatteryAndPluggedInRequired.statusLine)
        == "On battery — you chose mains power only")
  }

  @Test("every reason survives the trim with something left to read")
  func everyReasonKeepsItsDetail() {
    let reasons: [WakeReason] = [
      .agentsWorking(count: 3), .manualOverride, .paused(until: Date()), .noAgents,
      .batteryBelowFloor(percent: 5, floor: 20), .onBatteryAndPluggedInRequired, .lowPowerMode,
      .tooHot(state: .critical),
    ]
    for reason in reasons {
      let detail = NotificationPolicy.detail(inStatusLine: reason.statusLine)
      #expect(detail == reason.statusDetail, "for \(reason)")
      #expect(!detail.isEmpty)
    }
  }

  @Test("something that is already a detail comes back untouched")
  func passesThroughABareDetail() {
    #expect(
      NotificationPolicy.detail(inStatusLine: "Low Power Mode is on") == "Low Power Mode is on")
    #expect(NotificationPolicy.detail(inStatusLine: "") == "")
  }
}
