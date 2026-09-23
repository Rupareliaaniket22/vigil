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
      now: later.wall)
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
      now: now.wall)
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
