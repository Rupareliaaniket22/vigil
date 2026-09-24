import Foundation
import Testing

@testable import VigilCore

private func state(
  working: Int,
  waiting: Int = 0,
  holding: Bool,
  reason: WakeReason,
  outcome: SessionOutcome = .finished,
  cutShort: Bool = false
) -> NotificationPolicy.State {
  NotificationPolicy.State(
    workingCount: working, waitingCount: waiting, isHolding: holding, reason: reason,
    outcome: outcome, cutShort: cutShort)
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

  /// The whole of the repair, in the smallest form it has: work stopping is not
  /// the run stopping. An agent that leaves `working` for a permission prompt is
  /// still in the middle of the run.
  @Test("a session waiting on its user keeps the run alive")
  func waitingIsNotFinished() {
    let event = NotificationPolicy.event(
      from: state(working: 1, holding: true, reason: .agentsWorking(count: 1)),
      to: state(working: 0, waiting: 1, holding: false, reason: .noAgents))
    #expect(event == nil)
  }

  @Test("the run ends when the last waiting session ends too")
  func theRunEndsWhenNothingIsLeft() {
    let event = NotificationPolicy.event(
      from: state(working: 0, waiting: 1, holding: false, reason: .noAgents),
      to: state(working: 0, holding: false, reason: .noAgents))
    #expect(event == .allAgentsFinished(count: 1))
  }

  @Test(
    "how the run ended decides what is said",
    arguments: [
      (SessionOutcome.finished, NotificationPolicy.Event.allAgentsFinished(count: 2)),
      (.endedBadly, .runEndedBadly(count: 2)),
      (.lostContact, .lostContact(count: 2)),
    ])
  func theOutcomePicksTheEvent(outcome: SessionOutcome, expected: NotificationPolicy.Event) {
    let event = NotificationPolicy.event(
      from: state(working: 2, holding: true, reason: .agentsWorking(count: 2)),
      to: state(working: 0, holding: false, reason: .noAgents, outcome: outcome))
    #expect(event == expected)
  }

  /// A run is only as good as its worst ending: one clean `Stop` does not speak
  /// for the session that vanished beside it.
  @Test("a run is judged by its least certain ending")
  func theWorstOutcomeWins() {
    #expect(max(SessionOutcome.finished, .endedBadly) == .endedBadly)
    #expect(max(SessionOutcome.endedBadly, .lostContact) == .lostContact)
    #expect(max(SessionOutcome.finished, .lostContact) == .lostContact)
  }

  @Test("warns when a guardrail drops the hold mid-run")
  func warnsOnGuardrail() {
    let reason = WakeReason.batteryBelowFloor(percent: 18, floor: 20)
    let event = NotificationPolicy.event(
      from: state(working: 1, holding: true, reason: .agentsWorking(count: 1)),
      to: state(working: 1, holding: false, reason: reason))
    #expect(event == .guardrailStoppedHold(reason: reason))
  }

  /// Vigil never holds the Mac awake for a session that is waiting on its user,
  /// so a guardrail takes nothing away from one and has nothing to report.
  @Test("a guardrail firing over nothing but waiting sessions is not an alarm")
  func silentGuardrailOverWaitingWork() {
    let event = NotificationPolicy.event(
      from: state(working: 0, waiting: 2, holding: false, reason: .noAgents),
      to: state(
        working: 0, waiting: 2, holding: false,
        reason: .batteryBelowFloor(percent: 18, floor: 20)))
    #expect(event == nil)
  }

  @Test("a guardrail firing with nothing running is not worth saying")
  func silentGuardrailWhenIdle() {
    let event = NotificationPolicy.event(
      from: state(working: 0, holding: false, reason: .noAgents),
      to: state(working: 0, holding: false, reason: .batteryBelowFloor(percent: 18, floor: 20)))
    #expect(event == nil)
  }

  /// Battery already at 12% when the run is started. Nothing transitions — no
  /// hold begins, so no hold ends — and the app used to say nothing at all
  /// about the one job it has. The person finds out by coming back to a Mac
  /// that went to sleep an hour into a two-hour run.
  @Test("warns when work starts with a guardrail already in force")
  func warnsWhenAGuardrailWasAlreadyThere() {
    let reason = WakeReason.batteryBelowFloor(percent: 12, floor: 20)
    let event = NotificationPolicy.event(
      from: state(working: 0, holding: false, reason: reason),
      to: state(working: 1, holding: false, reason: reason))
    #expect(event == .guardrailPreventedHold(reason: reason))
  }

  /// Every guardrail, not just the battery one it was found with.
  @Test(
    "every guardrail warns when work starts underneath it",
    arguments: [
      WakeReason.batteryBelowFloor(percent: 12, floor: 20),
      .onBatteryAndPluggedInRequired,
      .lowPowerMode,
      .tooHot(state: .serious),
    ])
  func everyGuardrailWarnsOnStart(reason: WakeReason) {
    let event = NotificationPolicy.event(
      from: state(working: 0, holding: false, reason: reason),
      to: state(working: 2, holding: false, reason: reason))
    #expect(event == .guardrailPreventedHold(reason: reason))
  }

  /// The model re-evaluates every five seconds, and a low battery stays low.
  @Test("the blocked-hold warning fires once, not for every tick or every agent")
  func warnsOnceWhileTheGuardrailPersists() {
    let reason = WakeReason.lowPowerMode
    let idle = state(working: 0, holding: false, reason: reason)
    let started = state(working: 1, holding: false, reason: reason)
    #expect(NotificationPolicy.event(from: idle, to: started) != nil)
    // Same tick repeated.
    #expect(NotificationPolicy.event(from: started, to: started) == nil)
    // A second agent joining is not a second occasion to say it.
    #expect(
      NotificationPolicy.event(from: started, to: state(working: 2, holding: false, reason: reason))
        == nil)
  }

  /// A pause is not a guardrail, here either — starting work during one is the
  /// user's own arrangement, and the app has already been told.
  @Test("starting work during a pause says nothing")
  func startingDuringAPauseIsSilent() {
    let paused = WakeReason.paused(until: Date())
    let event = NotificationPolicy.event(
      from: state(working: 0, holding: false, reason: paused),
      to: state(working: 1, holding: false, reason: paused))
    #expect(event == nil)
  }

  /// Work starting normally still says nothing — the case this sits next to.
  @Test("starting work with no guardrail is still silent")
  func startingNormallyIsSilent() {
    let event = NotificationPolicy.event(
      from: state(working: 0, holding: false, reason: .noAgents),
      to: state(working: 1, holding: true, reason: .agentsWorking(count: 1)))
    #expect(event == nil)
  }

  /// The two guardrail warnings must never both be candidates for the same
  /// transition: one needs a hold that ended, the other needs one that never
  /// began. This is the transition that looks like both from a distance.
  @Test("a hold that ended is the stopped warning, not the prevented one")
  func theTwoGuardrailWarningsAreDisjoint() {
    let reason = WakeReason.tooHot(state: .serious)
    // A manual hold with nothing running, then work starts and heat cuts in:
    // a hold did end, so this belongs to the other rule.
    let event = NotificationPolicy.event(
      from: state(working: 0, holding: true, reason: .manualOverride),
      to: state(working: 1, holding: false, reason: reason))
    #expect(event == .guardrailStoppedHold(reason: reason))
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

  /// `GuardrailKind` is a second opinion about which reasons are guardrails,
  /// and a second opinion that can disagree is a bug waiting for a new case.
  @Test("every guardrail has a kind, and nothing else does")
  func guardrailKindsMatchTheReasons() {
    let reasons: [WakeReason] = [
      .agentsWorking(count: 3), .manualOverride, .paused(until: Date()), .noAgents,
      .batteryBelowFloor(percent: 5, floor: 20), .onBatteryAndPluggedInRequired, .lowPowerMode,
      .tooHot(state: .critical),
    ]
    for reason in reasons {
      #expect(
        (NotificationPolicy.GuardrailKind(reason) != nil) == reason.isGuardrail, "for \(reason)")
    }
    // And the numbers a reason carries are not part of its identity: a battery
    // ticking down one percent at a time is one guardrail, not five.
    #expect(
      NotificationPolicy.GuardrailKind(.batteryBelowFloor(percent: 19, floor: 20))
        == NotificationPolicy.GuardrailKind(.batteryBelowFloor(percent: 4, floor: 20)))
    #expect(
      NotificationPolicy.GuardrailKind(.tooHot(state: .serious))
        == NotificationPolicy.GuardrailKind(.tooHot(state: .critical)))
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

/// Everything Vigil would actually make a noise about, walked the way the model
/// walks it: one snapshot at a time, each scored against the one before it.
private func soundsHeard(
  through ticks: [NotificationPolicy.State],
  completionSoundEnabled: Bool = true
) -> [NotificationPolicy.Sound] {
  var heard: [NotificationPolicy.Sound] = []
  for (previous, current) in zip(ticks, ticks.dropFirst()) {
    guard let event = NotificationPolicy.event(from: previous, to: current) else { continue }
    if let sound = NotificationPolicy.sound(
      for: event.announcement, cutShort: current.cutShort,
      completionSoundEnabled: completionSoundEnabled)
    {
      heard.append(sound)
    }
  }
  return heard
}

@Suite("The sound a finished run makes")
struct CompletionSoundTests {

  @Test("a run that finishes is worth a sound")
  func aFinishedRunChimes() {
    #expect(
      soundsHeard(through: [
        state(working: 1, holding: true, reason: .agentsWorking(count: 1)),
        state(working: 0, holding: false, reason: .noAgents),
      ]) == [.completion])
  }

  /// The whole of the anti-spam rule, and it is inherited rather than added:
  /// three agents stopping is three transitions, and only the one that reaches
  /// zero is an event at all.
  @Test("three agents finishing seconds apart make one sound, not three")
  func oneSoundPerRunNotPerAgent() {
    #expect(
      soundsHeard(through: [
        state(working: 3, holding: true, reason: .agentsWorking(count: 3)),
        // A tick with nothing in it, because the model runs every five seconds.
        state(working: 3, holding: true, reason: .agentsWorking(count: 3)),
        state(working: 2, holding: true, reason: .agentsWorking(count: 2)),
        state(working: 1, holding: true, reason: .agentsWorking(count: 1)),
        state(working: 0, holding: false, reason: .noAgents),
        // And the tick after, which must not say it again.
        state(working: 0, holding: false, reason: .noAgents),
      ]) == [.completion])
  }

  @Test("three agents finishing inside one tick are also one sound")
  func oneSoundWhenTheyAllStopAtOnce() {
    #expect(
      soundsHeard(through: [
        state(working: 3, holding: true, reason: .agentsWorking(count: 3)),
        state(working: 0, holding: false, reason: .noAgents),
      ]) == [.completion])
  }

  /// The run was killed by a battery floor, not finished. It still ends with
  /// every agent stopping, so the completion rule fires for it — and a chime
  /// there would be the app saying "done" a minute after warning that it might
  /// not finish.
  @Test("a run a guardrail cut short does not get to sound finished")
  func stoppedShortDoesNotChime() {
    #expect(
      soundsHeard(through: [
        state(working: 2, holding: true, reason: .agentsWorking(count: 2)),
        state(working: 2, holding: false, reason: .lowPowerMode, cutShort: true),
        state(working: 0, holding: false, reason: .lowPowerMode, cutShort: true),
      ]) == [.warning])
  }

  /// Work that began under a guardrail was never held awake at all, so its
  /// ending is not a completion either.
  @Test("work that never got a hold does not sound finished")
  func preventedHoldDoesNotChimeOnTheWayOut() {
    let low = WakeReason.batteryBelowFloor(percent: 12, floor: 20)
    #expect(
      soundsHeard(through: [
        state(working: 0, holding: false, reason: low, cutShort: true),
        state(working: 1, holding: false, reason: low, cutShort: true),
        state(working: 0, holding: false, reason: low, cutShort: true),
      ]).isEmpty)
  }

  /// A pause is the user's own arrangement, not a guardrail, and work that
  /// finishes during one finished.
  @Test("a run that finishes during a pause still chimes")
  func pausedRunsStillChime() {
    #expect(
      soundsHeard(through: [
        state(working: 2, holding: false, reason: .paused(until: Date())),
        state(working: 0, holding: false, reason: .paused(until: Date())),
      ]) == [.completion])
  }

  @Test("turning the sound off leaves a finished run silent")
  func theSwitchWorks() {
    #expect(
      soundsHeard(
        through: [
          state(working: 1, holding: true, reason: .agentsWorking(count: 1)),
          state(working: 0, holding: false, reason: .noAgents),
        ], completionSoundEnabled: false
      ).isEmpty)
  }

  /// The switch is about the noise a run makes when it ends, and all three
  /// endings are that noise.
  @Test(
    "turning the sound off silences every ending, not just the happy one",
    arguments: [SessionOutcome.finished, .endedBadly, .lostContact])
  func theSwitchCoversEveryEnding(outcome: SessionOutcome) {
    #expect(
      soundsHeard(
        through: [
          state(working: 1, holding: true, reason: .agentsWorking(count: 1)),
          state(working: 0, holding: false, reason: .noAgents, outcome: outcome),
        ], completionSoundEnabled: false
      ).isEmpty)
  }

  /// A run that stopped without finishing is still over, and the person it is
  /// over for is in another room. They get a sound — just never the one that
  /// means their work is waiting for them.
  @Test(
    "a run that did not finish makes a different noise, not no noise",
    arguments: [SessionOutcome.endedBadly, .lostContact])
  func anUnfinishedRunStillSpeaks(outcome: SessionOutcome) {
    #expect(
      soundsHeard(through: [
        state(working: 1, holding: true, reason: .agentsWorking(count: 1)),
        state(working: 0, holding: false, reason: .noAgents, outcome: outcome),
      ]) == [.warning])
  }

  /// The switch turns off a chime. It does not turn off the one alert in this
  /// app that the user has to act on.
  @Test("the guardrail alarm keeps its own sound either way", arguments: [true, false])
  func theAlarmIsNotTheChime(soundEnabled: Bool) {
    #expect(
      NotificationPolicy.sound(
        for: .guardrailStoppedHold, cutShort: true, completionSoundEnabled: soundEnabled)
        == .warning)
  }

  /// It fires as work begins, with the person still at the keyboard.
  @Test("the blocked-hold warning stays silent", arguments: [true, false])
  func preventedHoldIsSilent(soundEnabled: Bool) {
    #expect(
      NotificationPolicy.sound(
        for: .guardrailPreventedHold, cutShort: true, completionSoundEnabled: soundEnabled) == nil)
  }

  /// Nothing but a run finishing may ever make the pleasant sound, under any
  /// combination of the two things the rule reads.
  @Test("only a finished run is ever the completion sound")
  func nothingElseChimes() {
    for announcement in NotificationPolicy.Announcement.allCases {
      for cutShort in [true, false] {
        let sound = NotificationPolicy.sound(
          for: announcement, cutShort: cutShort, completionSoundEnabled: true)
        if sound == .completion {
          #expect(announcement == .allAgentsFinished && !cutShort, "for \(announcement)")
        }
      }
    }
  }

  @Test("every event says which of the five it is")
  func eventsKnowTheirAnnouncement() {
    let finished = NotificationPolicy.Event.allAgentsFinished(count: 2)
    let badly = NotificationPolicy.Event.runEndedBadly(count: 2)
    let lost = NotificationPolicy.Event.lostContact(count: 2)
    let stopped = NotificationPolicy.Event.guardrailStoppedHold(reason: .lowPowerMode)
    let prevented = NotificationPolicy.Event.guardrailPreventedHold(reason: .lowPowerMode)
    #expect(finished.announcement == .allAgentsFinished)
    #expect(badly.announcement == .runEndedBadly)
    #expect(lost.announcement == .lostContact)
    #expect(stopped.announcement == .guardrailStoppedHold)
    #expect(prevented.announcement == .guardrailPreventedHold)
    #expect(!finished.announcement.isGuardrail)
    #expect(stopped.announcement.isGuardrail)
    #expect(prevented.announcement.isGuardrail)
    #expect([finished, badly, lost].allSatisfy { $0.announcement.endsARun })
    #expect([stopped, prevented].allSatisfy { !$0.announcement.endsARun })
  }
}

/// The app's loop, with the app taken out of it.
///
/// `AppModel.reevaluate` in miniature: prune, read what is left, decide, and
/// hand all three to the watch. Nothing here builds a `NotificationPolicy.State`
/// by hand, and that is the point — the bug this file was rewritten for was
/// never in the rules, it was in what the model handed them. A test that writes
/// `workingCount: 0` itself cannot see an agent leave `working` for a permission
/// prompt, because it has already decided that is what happened.
///
/// Events go in by their host's own name and are mapped by the host's own
/// `AgentIntegration`, so `PermissionRequest` becomes `waiting` and
/// `StopFailure` becomes `idle` here for exactly the reason they do in the
/// running app — through the entry Vigil would have installed, not through a
/// state a test picked.
private struct Loop {
  var store = SessionStore(staleAfter: 300)
  var watch = NotificationPolicy.Watch()
  var conditions = PowerConditions()
  var settings = WakeSettings()
  var pausedUntil: Timestamp?
  var manualOverride = false
  var completionSoundEnabled = true
  var now = Timestamp.now

  /// Post a hook event, the way the bridge does.
  ///
  /// `payload` is the value of whichever field the host matches this event on —
  /// Claude Code's `notification_type`, Codex's `SessionStart` source. Resolved
  /// through the entries Vigil installs rather than through
  /// `state(for:)`, so a test cannot post a state the host would never have
  /// produced: an event whose only registrations are matched, arriving with a
  /// value none of them names, fires nothing at all, exactly as it does in the
  /// running app.
  mutating func hook(
    _ agent: AgentKind, _ session: String, _ event: String, payload: String? = nil
  ) {
    guard let integration = AgentIntegration.all.first(where: { $0.id == agent }) else {
      Issue.record("no integration for \(agent.rawValue)")
      return
    }
    let entries = integration.registrations.filter { $0.event == event }
    let fired = entries.first { entry in
      guard let matcher = entry.matcher else { return payload == nil }
      guard let payload else { return false }
      return matcher.split(separator: "|").contains { $0 == payload }
    }
    guard let fired else {
      // Either the host runs no hook for this payload, or the test named an
      // event Vigil does not register for — which `state(for:)` would have
      // answered `.idle` to, silently ending the run.
      if entries.isEmpty { Issue.record("\(agent.rawValue) does not register for \(event)") }
      return
    }
    store.apply(
      AgentEvent(agent: agent, sessionID: session, state: fired.state, event: event),
      now: now)
  }

  /// One pass of the five-second loop.
  @discardableResult
  mutating func tick() -> NotificationPolicy.Spoken? {
    let expired = store.prune(now: now)
    let sessions = store.all(now: now)
    let decision = WakePolicy.decide(
      sessions: sessions, conditions: conditions, settings: settings,
      manualOverride: manualOverride, pausedUntil: pausedUntil, now: now)
    return watch.observe(
      sessions: sessions, expired: expired, isHolding: decision.holdIdleAssertion,
      reason: decision.reason, completionSoundEnabled: completionSoundEnabled, now: now)
  }

  /// Tick for this long with nothing reporting — an agent that went away.
  @discardableResult
  mutating func silence(for seconds: TimeInterval) -> [NotificationPolicy.Spoken] {
    heard(for: seconds) { _ in }
  }

  /// Tick for this long with a session reporting a tool call each time.
  @discardableResult
  mutating func working(
    _ agent: AgentKind, _ session: String, _ event: String, for seconds: TimeInterval
  ) -> [NotificationPolicy.Spoken] {
    heard(for: seconds) { $0.hook(agent, session, event) }
  }

  private mutating func heard(
    for seconds: TimeInterval, each step: (inout Loop) -> Void
  ) -> [NotificationPolicy.Spoken] {
    var spoken: [NotificationPolicy.Spoken] = []
    var elapsed: TimeInterval = 0
    while elapsed < seconds {
      now = now.advanced(by: 5)
      elapsed += 5
      step(&self)
      if let said = tick() { spoken.append(said) }
    }
    return spoken
  }
}

@Suite("What Vigil says about a real run")
struct RunAnnouncementTests {

  /// The worst of the four, and the one that hits everybody not running in
  /// bypass-permissions mode. Claude Code's `Notification` event means "I am
  /// asking you something", which is `waiting` — not `working`. Counting the
  /// run as over there announced "Agent finished — your Mac can sleep normally
  /// now", with the chime, while the agent sat at the approval prompt.
  @Test("a permission prompt is not a finished run")
  func aPermissionPromptSaysNothing() {
    var loop = Loop()
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    #expect(loop.tick() == nil, "starting is not an announcement")

    loop.hook(.claudeCode, "s", "Notification", payload: "permission_prompt")
    #expect(loop.tick() == nil, "an agent asking permission has not finished")

    loop.hook(.claudeCode, "s", "PreToolUse")
    #expect(loop.tick() == nil, "and answering it is not an announcement either")

    loop.hook(.claudeCode, "s", "Stop")
    #expect(
      loop.tick()
        == NotificationPolicy.Spoken(
          event: .allAgentsFinished(count: 1), sound: .completion))
  }

  /// The arithmetic of the old rule, stated as the user experienced it: every
  /// approval was a chime, and the real ending was one more.
  @Test("five approvals in a run are still one chime", arguments: [1, 3, 5])
  func approvalsDoNotChime(approvals: Int) {
    var loop = Loop()
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    var spoken = [loop.tick()].compactMap { $0 }

    for _ in 0..<approvals {
      loop.hook(.claudeCode, "s", "Notification", payload: "permission_prompt")
      spoken += [loop.tick()].compactMap { $0 }
      loop.now = loop.now.advanced(by: 30)
      loop.hook(.claudeCode, "s", "PostToolUse")
      spoken += [loop.tick()].compactMap { $0 }
    }

    loop.hook(.claudeCode, "s", "Stop")
    spoken += [loop.tick()].compactMap { $0 }

    #expect(spoken.map(\.event) == [.allAgentsFinished(count: 1)])
    #expect(spoken.compactMap(\.sound) == [.completion])
  }

  @Test("a run that reports Stop is a finished run")
  func aCleanStopChimes() {
    var loop = Loop()
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    loop.tick()
    loop.hook(.claudeCode, "s", "Stop")
    let spoken = loop.tick()
    #expect(spoken?.event == .allAgentsFinished(count: 1))
    #expect(spoken?.sound == .completion)
  }

  /// `StopFailure` is Claude Code's own event for a turn that ended on an API
  /// error, a context overflow or a tool call it could not parse — a third of
  /// the turns in one afternoon's trace. It is an idle event, so the hold is
  /// released for it, and the old rule could not tell it from `Stop`.
  @Test("a turn that ended in an error is not a turn that finished")
  func stopFailureDoesNotChime() {
    var loop = Loop()
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    loop.tick()
    loop.hook(.claudeCode, "s", "StopFailure")
    let spoken = loop.tick()
    #expect(spoken?.event == .runEndedBadly(count: 1))
    #expect(spoken?.sound == .warning, "over, and told so — but never congratulated")
  }

  /// Codex's `Interrupt` is the user pressing escape. Being congratulated for
  /// stopping something on purpose is the same lie from the other direction.
  @Test("pressing escape is not finishing")
  func interruptDoesNotChime() {
    var loop = Loop()
    loop.tick()
    loop.hook(.codex, "c", "UserPromptSubmit")
    loop.tick()
    loop.hook(.codex, "c", "Interrupt")
    #expect(loop.tick()?.event == .runEndedBadly(count: 1))
  }

  /// Codex's ordinary ending, beside the one above, so the rule cannot be read
  /// as "Codex never chimes".
  @Test("Codex stopping normally still chimes")
  func codexStopChimes() {
    var loop = Loop()
    loop.tick()
    loop.hook(.codex, "c", "UserPromptSubmit")
    loop.tick()
    loop.hook(.codex, "c", "Stop")
    #expect(loop.tick()?.sound == .completion)
  }

  /// Nobody said the work was done. The host crashed, the terminal closed, the
  /// Mac woke up with the run already gone — and Vigil gave up on the session
  /// when it went stale. Chiming "finished" for an agent we simply lost is the
  /// opposite of the truth.
  @Test("an agent Vigil loses is not an agent that finished")
  func aLostAgentIsNotAFinishedOne() {
    var loop = Loop()
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    loop.tick()

    let spoken = loop.silence(for: 320)
    #expect(spoken.map(\.event) == [.lostContact(count: 1)])
    #expect(spoken.compactMap(\.sound) == [.warning])
  }

  /// The overnight version of the case above: the agent stopped at a permission
  /// prompt and nobody was awake to answer it.
  @Test("an agent abandoned at a prompt is lost, not finished")
  func aPromptNobodyAnsweredIsNotAFinishedRun() {
    var loop = Loop()
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    loop.tick()
    loop.hook(.claudeCode, "s", "Notification", payload: "permission_prompt")
    loop.tick()

    let spoken = loop.silence(for: 320)
    #expect(spoken.map(\.event) == [.lostContact(count: 1)])
  }

  /// One clean ending does not speak for the session that vanished beside it.
  ///
  /// Two sessions of the *same* host, deliberately. That is what makes them one
  /// run: the rule below is about a run's own sessions, and using two different
  /// agents here made it look like a rule about the whole Mac, which is the
  /// reading that turned into `outcomeIsScopedToItsHost`.
  @Test("a run is judged by its least certain ending, not its best one")
  func mixedEndingsTakeTheWorst() {
    var loop = Loop()
    loop.tick()
    loop.hook(.claudeCode, "a", "UserPromptSubmit")
    loop.hook(.claudeCode, "b", "UserPromptSubmit")
    loop.tick()

    // One finishes properly. The run is still live, so nothing is said.
    loop.hook(.claudeCode, "a", "Stop")
    #expect(loop.tick() == nil)

    // The other is never heard from again.
    let spoken = loop.silence(for: 320)
    #expect(spoken.map(\.event) == [.lostContact(count: 1)])
    #expect(spoken.compactMap(\.sound) == [.warning])
  }

  /// The accumulator is per host, and it has to be.
  ///
  /// It used to be one value for the whole Mac, cleared only when nothing
  /// anywhere was working or waiting. With four integrations wired up that is a
  /// state a working day may never reach, so one escaped Codex turn relabelled
  /// every clean Claude Code run after it as a failure and swapped the
  /// completion chime for the warning sound — observed live, a `StopFailure` at
  /// 03:12 still poisoning announcements minutes later because the user's own
  /// session never let the count reach zero.
  @Test("one host's bad ending does not relabel another host's clean run")
  func outcomeIsScopedToItsHost() {
    var loop = Loop()
    loop.tick()
    loop.hook(.codex, "bad", "UserPromptSubmit")
    loop.hook(.claudeCode, "good", "UserPromptSubmit")
    loop.tick()

    // Codex's turn is escaped out of. That is Codex's run ending, badly.
    loop.hook(.codex, "bad", "Interrupt")
    let codexEnding = loop.tick()
    #expect(codexEnding?.event == .runEndedBadly(count: 1))

    // Claude Code keeps going, then finishes cleanly. Its run is its own.
    loop.hook(.claudeCode, "good", "PostToolUse")
    #expect(loop.tick() == nil)
    loop.hook(.claudeCode, "good", "Stop")
    let spoken = loop.tick()
    #expect(spoken?.event == .allAgentsFinished(count: 1))
    #expect(spoken?.sound == .completion)
  }

  /// The same scoping, one tick later rather than one host over: a host whose
  /// run has already ended and been announced does not carry its outcome into
  /// its next run.
  @Test("a host's next run is judged on its own ending")
  func outcomeClearsWithTheRunThatEarnedIt() {
    var loop = Loop()
    loop.tick()
    loop.hook(.claudeCode, "first", "UserPromptSubmit")
    loop.tick()
    loop.hook(.claudeCode, "first", "StopFailure")
    #expect(loop.tick()?.event == .runEndedBadly(count: 1))

    loop.hook(.claudeCode, "second", "UserPromptSubmit")
    loop.tick()
    loop.hook(.claudeCode, "second", "Stop")
    #expect(loop.tick()?.sound == .completion)
  }

  /// Two hosts finishing on the same tick are still one sentence and one sound.
  ///
  /// Scoping the accumulator per host does not mean announcing per host: the
  /// sound is a function of one event, which is the whole reason three agents
  /// finishing together make one noise. Hosts ending on the same tick get the
  /// same fold — counts added, outcome the worse of the two.
  @Test("hosts that end together are announced together")
  func simultaneousEndingsFoldIntoOne() {
    var loop = Loop()
    loop.tick()
    loop.hook(.claudeCode, "a", "UserPromptSubmit")
    loop.hook(.codex, "b", "UserPromptSubmit")
    loop.tick()

    loop.hook(.claudeCode, "a", "Stop")
    loop.hook(.codex, "b", "Interrupt")
    let spoken = loop.tick()
    #expect(spoken?.event == .runEndedBadly(count: 2))
    #expect(spoken?.sound == .warning)
  }

  /// A Mac that slept through the end of a run wakes up with the closing event
  /// already in the store and the row already past its staleness window, so the
  /// session is pruned having genuinely reported that it finished.
  @Test("an ending Vigil slept through is still an ending")
  func anEndingSeenOnlyAtPruneTimeIsStillClean() {
    var loop = Loop()
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    loop.tick()

    // The Stop lands, and then the Mac sleeps before the next five-second tick.
    loop.hook(.claudeCode, "s", "Stop")
    loop.now = loop.now.advanced(by: 400)
    let spoken = loop.tick()
    #expect(spoken?.event == .allAgentsFinished(count: 1))
    #expect(spoken?.sound == .completion)
  }

  @Test("the switch silences the chime without silencing the notification")
  func theSoundSwitchWorksThroughTheWholeLoop() {
    var loop = Loop()
    loop.completionSoundEnabled = false
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    loop.tick()
    loop.hook(.claudeCode, "s", "Stop")
    let spoken = loop.tick()
    #expect(spoken?.event == .allAgentsFinished(count: 1))
    #expect(spoken?.sound == nil)
  }
}

@Suite("Runs a guardrail killed")
struct GuardrailRunTests {

  /// The hole the old suppression left, walked step by step. Each stage is
  /// silent for a defensible reason, and the end of it was a full completion
  /// chime for a run the battery floor killed.
  @Test("a run killed by a guardrail that fired during a pause does not chime")
  func theGuardrailThatFiredDuringAPause() {
    var loop = Loop()
    loop.settings = WakeSettings(batteryFloorPercent: 20)
    loop.conditions = PowerConditions(batteryPercent: 80, isPluggedIn: false)
    loop.tick()

    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    loop.tick()

    // The user pauses Vigil. The hold drops, and a pause is their own
    // arrangement, so nothing is announced.
    loop.pausedUntil = loop.now.advanced(by: 60)
    #expect(loop.tick() == nil)

    // The battery falls below its floor while the pause is running. No hold
    // ends, because none was being held — so the guardrail warning, which
    // watches a hold end, never fires.
    loop.conditions.batteryPercent = 12
    #expect(loop.working(.claudeCode, "s", "PostToolUse", for: 60).isEmpty)

    // The pause expires with the guardrail in force. Still no hold, still no
    // transition, still nothing said.
    #expect(loop.working(.claudeCode, "s", "PostToolUse", for: 30).isEmpty)

    // The Mac sleeps and the agent dies with it.
    let spoken = loop.silence(for: 320)
    #expect(spoken.map(\.event) == [.lostContact(count: 1)])
    #expect(spoken.compactMap(\.sound).isEmpty, "the battery floor killed this run")
  }

  /// And the same walk with a healthy battery, so the silence above is read as
  /// the guardrail's doing rather than as `lostContact` being mute.
  @Test("the same run without the guardrail is told about out loud")
  func theSameRunOnMainsStillSpeaks() {
    var loop = Loop()
    loop.settings = WakeSettings(batteryFloorPercent: 20)
    loop.conditions = PowerConditions(batteryPercent: 80, isPluggedIn: false)
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    loop.tick()
    loop.pausedUntil = loop.now.advanced(by: 60)
    loop.tick()
    #expect(loop.working(.claudeCode, "s", "PostToolUse", for: 90).isEmpty)

    let spoken = loop.silence(for: 320)
    #expect(spoken.map(\.event) == [.lostContact(count: 1)])
    #expect(spoken.compactMap(\.sound) == [.warning])
  }

  /// A run cut short and then rescued still loses its chime, and the run after
  /// it gets one: the suppression belongs to a run, not to the app.
  @Test("the run after the one a guardrail cut short chimes again")
  func suppressionLastsExactlyOneRun() {
    var loop = Loop()
    loop.settings = WakeSettings(batteryFloorPercent: 20)
    loop.conditions = PowerConditions(batteryPercent: 12, isPluggedIn: false)
    loop.tick()

    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    #expect(loop.tick()?.announcement == .guardrailPreventedHold)
    loop.hook(.claudeCode, "s", "Stop")
    let cutShort = loop.tick()
    #expect(cutShort?.event == .allAgentsFinished(count: 1))
    #expect(cutShort?.sound == nil, "it finished, but not because Vigil kept the Mac awake")

    // Plugged back in, a new run.
    loop.conditions = PowerConditions(batteryPercent: 90, isPluggedIn: true)
    loop.now = loop.now.advanced(by: 30)
    loop.hook(.claudeCode, "t", "UserPromptSubmit")
    loop.tick()
    loop.hook(.claudeCode, "t", "Stop")
    #expect(loop.tick()?.sound == .completion)
  }

  /// The 3am noise path, and the only interruption level in this app that a
  /// Focus does not silence. A battery resting on its floor crosses it every
  /// few seconds, and every crossing was a fresh time-sensitive alert with a
  /// sound.
  @Test("a battery sitting on its floor raises one alarm, not twenty")
  func guardrailChatterIsOneAlarm() {
    var loop = Loop()
    loop.settings = WakeSettings(batteryFloorPercent: 20)
    loop.conditions = PowerConditions(batteryPercent: 21, isPluggedIn: false)
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    loop.tick()

    var alarms = 0
    for step in 0..<60 {
      loop.now = loop.now.advanced(by: 5)
      loop.conditions.batteryPercent = step.isMultiple(of: 2) ? 19 : 20
      loop.hook(.claudeCode, "s", "PostToolUse")
      if loop.tick()?.announcement == .guardrailStoppedHold { alarms += 1 }
    }
    #expect(alarms == 1, "five minutes of chatter is one event")
  }

  /// Hysteresis, not a mute button: a guardrail that genuinely cleared and came
  /// back is a new thing worth saying.
  @Test("a guardrail that has been clear for long enough warns again")
  func theAlarmRearms() {
    var loop = Loop()
    loop.settings = WakeSettings(batteryFloorPercent: 20)
    loop.conditions = PowerConditions(batteryPercent: 19, isPluggedIn: false)
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    // Working under a guardrail that was already there.
    #expect(loop.tick()?.announcement == .guardrailPreventedHold)

    // Plugged in: holding again, and the guardrail is clear.
    loop.conditions = PowerConditions(batteryPercent: 90, isPluggedIn: true)
    #expect(loop.working(.claudeCode, "s", "PostToolUse", for: 60).isEmpty)

    // Unplugged onto a flat battery: the hold ends, and this is the first time
    // that has happened in this run.
    loop.conditions = PowerConditions(batteryPercent: 19, isPluggedIn: false)
    loop.now = loop.now.advanced(by: 5)
    loop.hook(.claudeCode, "s", "PostToolUse")
    #expect(loop.tick()?.announcement == .guardrailStoppedHold)

    // Back on mains for longer than the re-arm window.
    loop.conditions = PowerConditions(batteryPercent: 90, isPluggedIn: true)
    #expect(loop.working(.claudeCode, "s", "PostToolUse", for: 700).isEmpty)

    // And down again. A separate occasion, hours later, gets its own warning.
    loop.conditions = PowerConditions(batteryPercent: 19, isPluggedIn: false)
    loop.now = loop.now.advanced(by: 5)
    loop.hook(.claudeCode, "s", "PostToolUse")
    #expect(loop.tick()?.announcement == .guardrailStoppedHold)
  }

  /// A different guardrail is a different thing to say, even inside the window
  /// the first one is suppressed for.
  @Test("one guardrail being suppressed does not suppress another")
  func kindsAreSuppressedSeparately() {
    var loop = Loop()
    loop.settings = WakeSettings(batteryFloorPercent: 20, thermalCeiling: .serious)
    loop.conditions = PowerConditions(batteryPercent: 21, isPluggedIn: false)
    loop.tick()
    loop.hook(.claudeCode, "s", "UserPromptSubmit")
    loop.tick()

    loop.conditions.batteryPercent = 19
    #expect(loop.tick()?.announcement == .guardrailStoppedHold)

    // Recovered, then hot.
    loop.conditions = PowerConditions(batteryPercent: 90, isPluggedIn: true)
    loop.now = loop.now.advanced(by: 5)
    loop.hook(.claudeCode, "s", "PostToolUse")
    loop.tick()
    loop.conditions.thermalState = .serious
    loop.now = loop.now.advanced(by: 5)
    loop.hook(.claudeCode, "s", "PostToolUse")
    #expect(loop.tick()?.announcement == .guardrailStoppedHold, "heat is not the battery")
  }
}
