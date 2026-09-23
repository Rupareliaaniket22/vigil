import Foundation
import Testing

@testable import VigilCore

@Suite("SessionStore")
struct SessionStoreTests {

  @Test("repeat events update a session rather than duplicating it")
  func updatesInPlace() {
    var store = SessionStore()
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "a", state: .working))
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "a", state: .idle))
    #expect(store.all().count == 1)
    #expect(store.all().first?.state == .idle)
  }

  @Test("fields absent from a later event are not cleared")
  func preservesKnownFields() {
    var store = SessionStore()
    store.apply(
      AgentEvent(
        agent: .claudeCode, sessionID: "a", state: .working,
        cwd: "/tmp/project", title: "refactor the parser"))
    // PostToolUse carries neither cwd nor title.
    store.apply(
      AgentEvent(agent: .claudeCode, sessionID: "a", state: .working, event: "PostToolUse"))

    let s = try! #require(store.all().first)
    #expect(s.cwd == "/tmp/project")
    #expect(s.title == "refactor the parser")
  }

  @Test("sessions that stop reporting are pruned")
  func prunesStaleSessions() {
    var store = SessionStore(staleAfter: 60)
    let t0 = Timestamp.now
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "a", state: .working), now: t0)

    #expect(store.all(now: t0.advanced(by: 30)).count == 1)
    #expect(store.all(now: t0.advanced(by: 90)).isEmpty)

    let dead = store.prune(now: t0.advanced(by: 90))
    #expect(dead.count == 1)
    #expect(store.isEmpty)
  }

  @Test("a crashed agent stuck in .working cannot hold the Mac awake forever")
  func stuckWorkingSessionExpires() {
    var store = SessionStore(staleAfter: 300)
    let t0 = Timestamp.now
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "ghost", state: .working), now: t0)

    let later = t0.advanced(by: 301)
    let decision = WakePolicy.decide(
      sessions: store.all(now: later),
      conditions: PowerConditions(),
      settings: WakeSettings(),
      now: later)
    #expect(!decision.holdIdleAssertion)
  }

  @Test("concurrent sessions are tracked independently")
  func multipleSessions() {
    var store = SessionStore()
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "a", state: .working))
    store.apply(AgentEvent(agent: .codex, sessionID: "b", state: .idle))
    store.apply(AgentEvent(agent: .cursor, sessionID: "c", state: .working))

    #expect(store.all().count == 3)
    #expect(store.active().count == 2)
  }
}

@Suite("AgentEvent decoding")
struct AgentEventDecodingTests {

  @Test("decodes a well-formed hook payload")
  func decodesHookPayload() throws {
    let json = """
      {"agent":"claude-code","session_id":"abc-123","state":"working",
       "event":"PostToolUse","pid":4242,"cwd":"/Users/x/proj","title":"fix the bug"}
      """
    let e = try AgentEvent.decode(from: Data(json.utf8))
    #expect(e.agent == .claudeCode)
    #expect(e.sessionID == "abc-123")
    #expect(e.state == .working)
    #expect(e.pid == 4242)
  }

  @Test("optional fields may be omitted")
  func decodesMinimalPayload() throws {
    let json = #"{"agent":"codex","session_id":"s","state":"idle"}"#
    let e = try AgentEvent.decode(from: Data(json.utf8))
    #expect(e.pid == nil)
    #expect(e.cwd == nil)
  }

  @Test("an unknown agent is accepted, so new tools work without a release")
  func acceptsUnknownAgent() throws {
    let json = #"{"agent":"some-new-tool","session_id":"s","state":"working"}"#
    let e = try AgentEvent.decode(from: Data(json.utf8))
    #expect(e.agent.rawValue == "some-new-tool")
  }

  @Test(
    "malformed payloads are rejected, not guessed at",
    arguments: [
      #"{"agent":"claude-code","state":"working"}"#,  // no session id
      #"{"agent":"claude-code","session_id":"s","state":"?"}"#,  // unknown state
      #"not json at all"#,
      #"{}"#,
    ])
  func rejectsMalformed(json: String) {
    #expect(throws: (any Error).self) {
      try AgentEvent.decode(from: Data(json.utf8))
    }
  }
}

@Suite("Session staleness uses a clock that cannot go backwards")
struct SessionClockTests {

  /// The failure this exists to prevent: NTP steps the wall clock back, the
  /// age of a dead `.working` session never passes the staleness window, and
  /// the Mac is held awake indefinitely by an agent that stopped hours ago.
  @Test("a wall clock jumping backwards cannot make a dead session immortal")
  func wallClockStepBackwardsStillExpires() {
    var store = SessionStore(staleAfter: 300)
    let t0 = Timestamp.now
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "ghost", state: .working), now: t0)

    // Real time moved on; the wall clock was corrected an hour backwards.
    let later = Timestamp(
      wall: t0.wall.addingTimeInterval(-3600),
      uptime: t0.uptime.advanced(by: .seconds(301))
    )

    #expect(store.all(now: later).isEmpty)
    #expect(store.prune(now: later).count == 1)
    #expect(store.isEmpty)
  }

  /// The same step forwards must not expire a session that is very much alive.
  @Test("a wall clock jumping forwards cannot kill a live session")
  func wallClockStepForwardsKeepsLiveSession() {
    var store = SessionStore(staleAfter: 300)
    let t0 = Timestamp.now
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "live", state: .working), now: t0)

    let later = Timestamp(
      wall: t0.wall.addingTimeInterval(86_400),
      uptime: t0.uptime.advanced(by: .seconds(5))
    )
    #expect(store.all(now: later).count == 1)
    #expect(store.prune(now: later).isEmpty)
  }

  @Test("elapsed time never reads as negative")
  func elapsedIsClamped() {
    let t0 = Timestamp.now
    #expect(t0.seconds(since: t0.advanced(by: 60)) == 0)
    #expect(t0.advanced(by: 60).seconds(since: t0) == 60)
  }
}

@Suite("Sessions belong to an agent, not just an id")
struct SessionIdentityTests {

  /// Session ids come from each host's own namespace and nothing stops two
  /// hosts choosing the same one — the hook's own `pid-NNNN` fallback collides
  /// outright. Keyed on the id alone they merged into one row, attributed to
  /// whichever agent reported first.
  @Test("two agents sharing a session id stay two sessions")
  func sameIdDifferentAgents() {
    var store = SessionStore()
    let now = Timestamp.now
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "shared", state: .working), now: now)
    store.apply(AgentEvent(agent: .cursor, sessionID: "shared", state: .idle), now: now)

    let all = store.all(now: now)
    #expect(all.count == 2)
    #expect(Set(all.map(\.id)).count == 2, "two sessions collapsed into one row")
    #expect(all.first { $0.agent == .claudeCode }?.state == .working)
    #expect(all.first { $0.agent == .cursor }?.state == .idle)
    #expect(store.active(now: now).count == 1)
  }

  /// And the flip side: one agent stopping must not release the hold the other
  /// still needs.
  @Test("stopping one of a colliding pair leaves the other working")
  func collidingIdsExpireIndependently() {
    var store = SessionStore()
    let now = Timestamp.now
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "shared", state: .working), now: now)
    store.apply(AgentEvent(agent: .codex, sessionID: "shared", state: .working), now: now)
    store.apply(AgentEvent(agent: .codex, sessionID: "shared", state: .idle), now: now)

    let decision = WakePolicy.decide(
      sessions: store.all(now: now),
      conditions: PowerConditions(),
      settings: WakeSettings(),
      now: now)
    #expect(decision.holdIdleAssertion)
    #expect(decision.reason == .agentsWorking(count: 1))
  }

  @Test("row order is stable when two sessions report at the same instant")
  func stableOrdering() {
    var store = SessionStore()
    let now = Timestamp.now
    for id in ["c", "a", "b"] {
      store.apply(AgentEvent(agent: .claudeCode, sessionID: id, state: .working), now: now)
    }
    #expect(store.all(now: now).map(\.sessionID) == ["a", "b", "c"])
  }
}

@Suite("A session's whole life")
struct SessionLifecycleTests {

  /// The ordinary arc, start to finish, with nothing else happening.
  @Test("starts, works, goes idle, is never heard from again")
  func theWholeArc() {
    var store = SessionStore(staleAfter: 300)
    let t0 = Timestamp.now

    store.apply(
      AgentEvent(
        agent: .claudeCode, sessionID: "s", state: .working, event: "UserPromptSubmit",
        cwd: "/tmp/p", title: "fix the parser"),
      now: t0)
    func holds(at t: Timestamp) -> Bool {
      WakePolicy.decide(
        sessions: store.all(now: t), conditions: PowerConditions(), settings: WakeSettings(),
        now: t
      ).holdIdleAssertion
    }

    #expect(holds(at: t0))

    // Working, and reporting every tool call.
    var t = t0
    for _ in 0..<10 {
      t = t.advanced(by: 20)
      store.apply(
        AgentEvent(agent: .claudeCode, sessionID: "s", state: .working, event: "PostToolUse"),
        now: t)
      #expect(holds(at: t), "a session that keeps reporting keeps the hold")
    }

    // Done. The hold goes immediately — not when the row does.
    t = t.advanced(by: 1)
    store.apply(
      AgentEvent(agent: .claudeCode, sessionID: "s", state: .idle, event: "Stop"), now: t)
    #expect(!holds(at: t), "idle releases the hold at once")
    #expect(store.all(now: t).count == 1, "but the row stays, so the panel can still show it")

    // And then silence. The row outlives the work by the staleness window, and
    // no longer.
    #expect(store.all(now: t.advanced(by: 299)).count == 1)
    #expect(store.all(now: t.advanced(by: 301)).isEmpty)
    #expect(store.prune(now: t.advanced(by: 301)).count == 1)
  }

  /// The failure mode that decides the staleness window: a host that dies
  /// mid-task never sends the event that would have released the hold.
  ///
  /// The window is the whole cost of that — the Mac stays awake for it, and no
  /// longer. Written down here because it is a number with a real price on both
  /// sides: shorter drops live runs whose agent is simply busy, longer leaves a
  /// dead one holding.
  @Test("a session that reports working and then dies holds for the window, and no longer")
  func workingThenTheProcessDies() {
    var store = SessionStore(staleAfter: 300)
    let t0 = Timestamp.now
    store.apply(
      AgentEvent(agent: .claudeCode, sessionID: "ghost", state: .working, pid: 4242), now: t0)

    func holds(at t: Timestamp) -> Bool {
      WakePolicy.decide(
        sessions: store.all(now: t), conditions: PowerConditions(), settings: WakeSettings(),
        now: t
      ).holdIdleAssertion
    }

    #expect(holds(at: t0.advanced(by: 299)), "still within the window")
    #expect(!holds(at: t0.advanced(by: 301)), "past it, the hold goes on its own")
    #expect(store.prune(now: t0.advanced(by: 301)).count == 1)
    #expect(store.isEmpty)
  }

  /// The same window, seen from the other side: a live agent whose tool call
  /// outlasts it is dropped exactly like a dead one, because the two look
  /// identical from here. Nothing in the loop distinguishes them.
  @Test("a live agent silent for longer than the window is dropped too")
  func aQuietButLiveAgentIsDropped() {
    var store = SessionStore(staleAfter: 300)
    let t0 = Timestamp.now
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "busy", state: .working), now: t0)

    // A single long tool call: PreToolUse at t0, PostToolUse six minutes later.
    let quiet = t0.advanced(by: 360)
    #expect(store.all(now: quiet).isEmpty, "the hold is already gone when the tool returns")

    // And the returning event resurrects it, rather than being ignored.
    store.apply(
      AgentEvent(agent: .claudeCode, sessionID: "busy", state: .working, event: "PostToolUse"),
      now: quiet)
    #expect(store.active(now: quiet).count == 1)
  }

  @Test("an event for a session we pruned starts a new one rather than being lost")
  func resurrectionAfterPruning() {
    var store = SessionStore(staleAfter: 60)
    let t0 = Timestamp.now
    store.apply(AgentEvent(agent: .codex, sessionID: "x", state: .working), now: t0)
    let later = t0.advanced(by: 61)
    store.prune(now: later)
    #expect(store.isEmpty)

    store.apply(AgentEvent(agent: .codex, sessionID: "x", state: .working), now: later)
    #expect(store.active(now: later).count == 1)
  }

  /// `isEmpty` answers about everything tracked, stale rows included, which is
  /// what `prune` needs of it. It is not the question the panel asks.
  @Test("isEmpty is about what is tracked, not about what is live")
  func isEmptyIsAboutStorage() {
    var store = SessionStore(staleAfter: 60)
    let t0 = Timestamp.now
    store.apply(AgentEvent(agent: .codex, sessionID: "x", state: .working), now: t0)
    let later = t0.advanced(by: 61)
    #expect(store.all(now: later).isEmpty, "nothing live")
    #expect(!store.isEmpty, "but still held, until something prunes it")
  }

  /// Hooks fire on every tool call, from every session, of every agent. The
  /// numbers here are absurd on purpose: whatever goes wrong at this size is
  /// not going to be noticed at three.
  @Test("thousands of sessions stay correct")
  func thousandsOfSessions() {
    var store = SessionStore(staleAfter: 300)
    let t0 = Timestamp.now
    let agents: [AgentKind] = [.claudeCode, .codex, .cursor, .gemini, .opencode]

    for i in 0..<10_000 {
      store.apply(
        AgentEvent(
          agent: agents[i % agents.count],
          sessionID: "s\(i)",
          // A third working, a third waiting, a third idle.
          state: [.working, .waiting, .idle][i % 3]
        ),
        // Spread across the window, so half of them are stale later on.
        now: t0.advanced(by: Double(i % 600))
      )
    }

    let now = t0.advanced(by: 600)
    let live = store.all(now: now)
    // 10,000 sessions across 600 one-second slots; the 300 most recent slots
    // are still inside the window.
    #expect(live.count == 4900, "everything quiet for 300s or less")
    #expect(live.map(\.lastSeen.uptime) == live.map(\.lastSeen.uptime).sorted(by: >))
    #expect(Set(live.map(\.id)).count == live.count, "no two rows share an id")

    let d = WakePolicy.decide(
      sessions: live, conditions: PowerConditions(), settings: WakeSettings(), now: now)
    #expect(d.reason == .agentsWorking(count: live.filter { $0.state == .working }.count))
    #expect(d.holdIdleAssertion)

    #expect(store.prune(now: now).count == 5100)
    #expect(store.all(now: now).count == 4900, "pruning drops the dead and only the dead")

    // And once every one of them goes quiet, nothing is left holding anything.
    let muchLater = now.advanced(by: 301)
    #expect(store.all(now: muchLater).isEmpty)
    #expect(
      !WakePolicy.decide(
        sessions: store.all(now: muchLater), conditions: PowerConditions(),
        settings: WakeSettings(), now: muchLater
      ).holdIdleAssertion)
  }

  /// Two hosts, one session id, one of them crashing. The other must not be
  /// pruned with it — this is the collision case, with time added.
  @Test("colliding session ids expire independently")
  func collidingIdsAgeSeparately() {
    var store = SessionStore(staleAfter: 300)
    let t0 = Timestamp.now
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "shared", state: .working), now: t0)
    store.apply(AgentEvent(agent: .codex, sessionID: "shared", state: .working), now: t0)

    // Codex keeps reporting; Claude Code stops.
    let later = t0.advanced(by: 301)
    store.apply(AgentEvent(agent: .codex, sessionID: "shared", state: .working), now: later)

    let live = store.all(now: later)
    #expect(live.count == 1)
    #expect(live.first?.agent == .codex)
    #expect(store.prune(now: later).map(\.agent) == [.claudeCode])
  }
}

@Suite("How a session's work ended")
struct SessionOutcomeTests {

  private func session(
    _ agent: AgentKind, _ event: String, now: Timestamp = .now
  ) -> AgentSession {
    guard let integration = AgentIntegration.all.first(where: { $0.id == agent }) else {
      Issue.record("no integration for \(agent.rawValue)")
      return AgentSession(
        event: AgentEvent(agent: agent, sessionID: "s", state: .idle), now: now)
    }
    var store = SessionStore()
    return store.apply(
      AgentEvent(
        agent: agent, sessionID: "s", state: integration.state(for: event), event: event),
      now: now)
  }

  @Test("a session still in flight has no outcome yet")
  func liveSessionsHaveNoOutcome() {
    #expect(session(.claudeCode, "PostToolUse").outcome == nil)
    // The one that matters: an agent stopped on a permission prompt has not
    // finished, and reading it as finished is what announced the end of a run
    // on every approval.
    #expect(session(.claudeCode, "Notification").outcome == nil)
    #expect(session(.claudeCode, "Notification").isLive)
  }

  @Test("a host reporting its ordinary ending reports a finish")
  func cleanEndings() {
    #expect(session(.claudeCode, "Stop").outcome == .finished)
    #expect(session(.claudeCode, "SessionEnd").outcome == .finished)
    #expect(session(.codex, "Stop").outcome == .finished)
    #expect(session(.gemini, "AfterAgent").outcome == .finished)
    #expect(session(.cursor, "afterAgentResponse").outcome == .finished)
  }

  @Test("the two endings that are not finishes")
  func unfinishedEndings() {
    #expect(session(.claudeCode, "StopFailure").outcome == .endedBadly)
    #expect(session(.codex, "Interrupt").outcome == .endedBadly)
  }

  /// The names belong to somebody else's vocabulary, so nothing stops the next
  /// host Vigil learns using `Interrupt` to mean something else entirely.
  @Test("an ending name is read only for the host that sends it")
  func namesAreNotSharedBetweenHosts() {
    #expect(session(.codex, "StopFailure").outcome == .finished)
    #expect(session(.claudeCode, "Interrupt").outcome == .finished)
  }

  /// An event name Vigil does not recognise still ends the turn — `state(for:)`
  /// calls anything unknown idle — and there is nothing in it to say the turn
  /// went wrong. Failing towards `finished` is the reading Vigil had before it
  /// could tell the two apart at all.
  @Test("an ending Vigil cannot classify reads as a finish")
  func unknownEndingsAreFinishes() {
    var store = SessionStore()
    let s = store.apply(
      AgentEvent(agent: .claudeCode, sessionID: "s", state: .idle, event: "SomethingNew"))
    #expect(s.outcome == .finished)
    let nameless = store.apply(
      AgentEvent(agent: .gemini, sessionID: "g", state: .idle))
    #expect(nameless.outcome == .finished)
  }

  /// `SessionOutcome` names two events that `AgentIntegration` also names, and
  /// the duplication is only safe while the two agree. This is the check that
  /// makes a disagreement a build failure instead of a chime on a dead run.
  @Test("every unfinished ending is an event that host actually sends")
  func theTableAgreesWithTheIntegrations() {
    for (agent, events) in SessionOutcome.unfinishedEndings {
      let integration = AgentIntegration.all.first { $0.id == agent }
      #expect(integration != nil, "\(agent.rawValue) is not an agent Vigil ships")
      for event in events {
        #expect(
          integration?.idleEvents.contains(event) == true,
          "\(agent.rawValue) does not send \(event) as an ending")
      }
    }
  }

  /// And the other direction, so the table cannot quietly stop covering a host:
  /// everything else a host sends to end a turn is a finish, by construction.
  @Test("every other ending a host sends is a finish")
  func everythingElseIsAFinish() {
    for integration in AgentIntegration.all {
      let unfinished = SessionOutcome.unfinishedEndings[integration.id] ?? []
      for event in integration.idleEvents where !unfinished.contains(event) {
        #expect(
          session(integration.id, event).outcome == .finished,
          "\(integration.id.rawValue) \(event)")
      }
    }
  }

  /// `state` alone cannot answer this: `Stop` and `StopFailure` both arrive as
  /// idle, and only the name says which one happened.
  @Test("the host's own event name survives into the session")
  func theEventNameIsKept() {
    var store = SessionStore()
    store.apply(
      AgentEvent(agent: .claudeCode, sessionID: "s", state: .working, event: "UserPromptSubmit"))
    #expect(store.all().first?.lastEvent == "UserPromptSubmit")
    store.apply(
      AgentEvent(agent: .claudeCode, sessionID: "s", state: .idle, event: "StopFailure"))
    #expect(store.all().first?.lastEvent == "StopFailure")
    // A payload with no name leaves the last one rather than blanking it.
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "s", state: .idle))
    #expect(store.all().first?.lastEvent == "StopFailure")
  }

  /// `active` answers the wake decision's question; `live` answers the
  /// notification's. They differ by exactly the sessions sitting at a prompt.
  @Test("live and active differ by the sessions waiting on a human")
  func liveIsNotActive() {
    var store = SessionStore()
    let now = Timestamp.now
    store.apply(
      AgentEvent(agent: .claudeCode, sessionID: "a", state: .working, event: "PostToolUse"),
      now: now)
    store.apply(
      AgentEvent(agent: .claudeCode, sessionID: "b", state: .waiting, event: "Notification"),
      now: now)
    store.apply(
      AgentEvent(agent: .claudeCode, sessionID: "c", state: .idle, event: "Stop"), now: now)

    #expect(store.all(now: now).count == 3)
    #expect(store.active(now: now).map(\.sessionID) == ["a"])
    #expect(Set(store.live(now: now).map(\.sessionID)) == ["a", "b"])
  }
}
