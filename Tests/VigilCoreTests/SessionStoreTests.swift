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
    let t0 = Date()
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "a", state: .working), now: t0)

    #expect(store.all(now: t0.addingTimeInterval(30)).count == 1)
    #expect(store.all(now: t0.addingTimeInterval(90)).isEmpty)

    let dead = store.prune(now: t0.addingTimeInterval(90))
    #expect(dead.count == 1)
    #expect(store.isEmpty)
  }

  @Test("a crashed agent stuck in .working cannot hold the Mac awake forever")
  func stuckWorkingSessionExpires() {
    var store = SessionStore(staleAfter: 300)
    let t0 = Date()
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "ghost", state: .working), now: t0)

    let later = t0.addingTimeInterval(301)
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
