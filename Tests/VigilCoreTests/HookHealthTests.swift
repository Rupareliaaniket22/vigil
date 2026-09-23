import Foundation
import Testing

@testable import VigilCore

/// Feed a run of endings a minute apart, so nothing falls off the horizon
/// while the ratio is being built.
private func health(
  _ endings: [SessionEnding],
  agent: AgentKind = .claudeCode,
  from start: Timestamp,
  spacing: TimeInterval = 60,
  configure: (inout HookHealth) -> Void = { _ in }
) -> HookHealth {
  var health = HookHealth()
  configure(&health)
  for (index, ending) in endings.enumerated() {
    health.record(ending, for: agent, now: start.advanced(by: Double(index) * spacing))
  }
  return health
}

private func run(_ timeouts: Int, _ idle: Int) -> [SessionEnding] {
  Array(repeating: .expiredWhileWorking, count: timeouts)
    + Array(repeating: .reportedIdle, count: idle)
}

@Suite("Noticing a host that stopped saying it had finished")
struct HookHealthTests {

  /// The bug this exists for, in its pure form: `Stop` is gone, so every turn
  /// runs out the clock. Nothing in the settings file changed and nothing else
  /// in Vigil can see it.
  @Test("a host that has lost its idle event is flagged")
  func lostVocabulary() {
    let t0 = Timestamp.now
    let health = health(run(10, 0), from: t0)
    let verdict = health.verdict(for: .claudeCode, now: t0.advanced(by: 700))

    #expect(verdict.endings == 10)
    #expect(verdict.timeouts == 10)
    #expect(verdict.timeoutShare == 1.0)
    #expect(verdict.isSuspect)
    #expect(health.suspectAgents(now: t0.advanced(by: 700)) == [.claudeCode])
  }

  /// And the reason it is a ratio. One agent killed mid-run looks exactly like
  /// a broken host from one ending away, so one ending must never be enough —
  /// nor must nine healthy endings with one kill among them.
  @Test("a single agent killed mid-run says nothing", arguments: [1, 2, 3])
  func oneKillIsNotASignal(kills: Int) {
    let t0 = Timestamp.now
    let health = health(run(kills, 12 - kills), from: t0)
    #expect(!health.verdict(for: .claudeCode, now: t0.advanced(by: 900)).isSuspect)
  }

  /// Below the minimum sample the ratio is not a ratio, however lopsided it
  /// looks. Three timeouts out of three is a Mac that slept twice; it is also
  /// exactly what a broken host looks like after three endings, which is why
  /// neither gets an accusation.
  @Test("nothing is said before there is enough to say it about", arguments: 1...7)
  func minimumSample(count: Int) {
    let t0 = Timestamp.now
    let health = health(run(count, 0), from: t0)
    let verdict = health.verdict(for: .claudeCode, now: t0.advanced(by: 600))

    #expect(verdict.timeoutShare == 1.0, "the ratio is damning")
    #expect(!verdict.isSuspect, "and there is still not enough of it to act on")
  }

  @Test("the eighth ending is where it starts")
  func exactlyTheMinimum() {
    let t0 = Timestamp.now
    #expect(health(run(8, 0), from: t0).verdict(for: .claudeCode, now: t0).isSuspect)
  }

  /// Strictly more than half. An even split is the one case where the evidence
  /// genuinely points both ways, and the tie goes to saying nothing.
  @Test(
    "the bar is more than half, not half",
    arguments: [
      (5, 5, false),
      (6, 6, false),
      (5, 4, true),
      (6, 5, true),
      (7, 3, true),
      (4, 6, false),
    ])
  func theBar(timeouts: Int, idle: Int, expected: Bool) {
    let t0 = Timestamp.now
    let health = health(run(timeouts, idle), from: t0)
    #expect(health.verdict(for: .claudeCode, now: t0.advanced(by: 3600)).isSuspect == expected)
  }

  /// A host fixed by an update has to stop being accused without Vigil being
  /// restarted. From a full window of nothing but timeouts it takes ten healthy
  /// endings to push the last of the evidence out — an afternoon's work, not a
  /// reinstall. Nine is deliberately checked too: the recovery is gradual, and
  /// a test that only showed the end of it would not notice the window
  /// silently growing.
  @Test("a host that is fixed clears as the good endings arrive")
  func recovery() {
    let t0 = Timestamp.now
    var health = health(run(20, 0), from: t0)
    #expect(health.verdict(for: .claudeCode, now: t0.advanced(by: 1200)).isSuspect)

    for index in 0..<9 {
      health.record(.reportedIdle, for: .claudeCode, now: t0.advanced(by: 1200 + Double(index)))
    }
    #expect(
      health.verdict(for: .claudeCode, now: t0.advanced(by: 1300)).isSuspect,
      "eleven of twenty is still more than half")

    health.record(.reportedIdle, for: .claudeCode, now: t0.advanced(by: 1300))
    let verdict = health.verdict(for: .claudeCode, now: t0.advanced(by: 1400))
    #expect(verdict.endings == 20, "the window stays full")
    #expect(verdict.timeouts == 10)
    #expect(!verdict.isSuspect)
  }

  /// Evidence about a host version the user stopped running a week ago is
  /// evidence about a program that no longer exists.
  @Test("endings older than the horizon stop counting")
  func horizon() {
    let t0 = Timestamp.now
    let health = health(run(10, 0), from: t0)
    #expect(health.verdict(for: .claudeCode, now: t0.advanced(by: 3600)).isSuspect)

    let tomorrow = t0.advanced(by: 25 * 60 * 60)
    let verdict = health.verdict(for: .claudeCode, now: tomorrow)
    #expect(verdict.endings == 0)
    #expect(!verdict.isSuspect)
  }

  /// Only the last `window` endings count, so a machine that has been running
  /// for a month cannot carry an old verdict forward on volume alone.
  @Test("the window is bounded")
  func bounded() {
    let t0 = Timestamp.now
    let health = health(run(40, 0), from: t0, spacing: 1)
    #expect(health.verdict(for: .claudeCode, now: t0.advanced(by: 60)).endings == 20)
  }

  /// One host going quiet must not implicate the other three.
  @Test("agents are judged separately")
  func perAgent() {
    let t0 = Timestamp.now
    var health = HookHealth()
    for index in 0..<10 {
      health.record(.expiredWhileWorking, for: .codex, now: t0.advanced(by: Double(index)))
      health.record(.reportedIdle, for: .claudeCode, now: t0.advanced(by: Double(index)))
    }
    let now = t0.advanced(by: 60)
    #expect(health.suspectAgents(now: now) == [.codex])
    #expect(health.warning(for: .claudeCode, now: now) == nil)
    #expect(health.warning(for: .codex, now: now) != nil)
  }

  @Test("an agent nobody has run is not an agent in trouble")
  func silence() {
    let health = HookHealth()
    let now = Timestamp.now
    #expect(health.isEmpty)
    #expect(
      health.verdict(for: .gemini, now: now) == .init(endings: 0, timeouts: 0, isSuspect: false))
    #expect(health.verdict(for: .gemini, now: now).timeoutShare == 0)
    #expect(health.suspectAgents(now: now).isEmpty)
  }

  @Test("the warning names the host and hedges honestly")
  func wording() {
    let t0 = Timestamp.now
    let health = health(run(10, 0), from: t0)
    let warning = try! #require(health.warning(for: .claudeCode, now: t0.advanced(by: 60)))

    #expect(warning.hasPrefix("Claude Code sessions have been ending by timeout"))
    #expect(warning.contains("may have changed"), "a ratio is not a proof and must not read as one")
  }

  /// An agent Vigil ships no integration for still gets a sentence, using the
  /// raw kind — the same fallback `AgentIntegration.displayName` makes.
  @Test("an agent we ship no integration for is still named")
  func unknownAgent() {
    let t0 = Timestamp.now
    let kind = AgentKind(rawValue: "some-new-tool")
    let health = health(run(10, 0), agent: kind, from: t0)
    #expect(health.warning(for: kind, now: t0)?.hasPrefix("some-new-tool sessions") == true)
  }
}

@Suite("Classifying how a session ended")
struct SessionEndingTests {

  private func session(_ state: AgentState, agent: AgentKind = .claudeCode) -> AgentSession {
    AgentSession(
      event: AgentEvent(agent: agent, sessionID: "s", state: state), now: .now)
  }

  @Test("a session still working when it aged out ran out the clock")
  func working() {
    #expect(HookHealth.ending(of: session(.working)) == .expiredWhileWorking)
  }

  @Test("a session that had gone idle reported itself")
  func idle() {
    #expect(HookHealth.ending(of: session(.idle)) == .reportedIdle)
  }

  /// The judgement call, pinned. A session blocked on a human who never came
  /// back tells us nothing about whether the host can still say "finished", and
  /// counting it as a timeout would load the dice against the only host that
  /// reports `waiting` at all.
  @Test("a session waiting on the user counts for neither side")
  func waiting() {
    #expect(HookHealth.ending(of: session(.waiting)) == nil)
  }

  /// End to end against the real store, because the classification is only
  /// worth anything if it matches what `prune` actually hands over.
  @Test("what prune gives up on is what gets counted")
  func throughTheStore() {
    var store = SessionStore(staleAfter: 60)
    var health = HookHealth()
    let t0 = Timestamp.now

    store.apply(AgentEvent(agent: .claudeCode, sessionID: "a", state: .working), now: t0)
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "b", state: .working), now: t0)
    // One of the two says it finished; the other never speaks again.
    store.apply(AgentEvent(agent: .claudeCode, sessionID: "b", state: .idle), now: t0)
    store.apply(AgentEvent(agent: .codex, sessionID: "c", state: .waiting), now: t0)

    let later = t0.advanced(by: 120)
    health.record(expired: store.prune(now: later), now: later)

    let claude = health.verdict(for: .claudeCode, now: later)
    #expect(claude.endings == 2)
    #expect(claude.timeouts == 1)
    #expect(health.verdict(for: .codex, now: later).endings == 0, "waiting is not counted")
  }

  /// The regression that started all of this, replayed: a host whose only idle
  /// event has stopped arriving. Each turn leaves the session `working`, it is
  /// pruned five minutes later, and the next prompt starts it over.
  @Test("a missing Stop event shows up as a run of timeouts")
  func missingStop() {
    var store = SessionStore(staleAfter: 300)
    var health = HookHealth()
    var clock = Timestamp.now

    for _ in 0..<10 {
      store.apply(AgentEvent(agent: .claudeCode, sessionID: "s", state: .working), now: clock)
      // No Stop, no StopFailure, no SessionEnd. The turn simply ends.
      clock = clock.advanced(by: 400)
      health.record(expired: store.prune(now: clock), now: clock)
    }

    #expect(health.verdict(for: .claudeCode, now: clock).isSuspect)
    #expect(health.warning(for: .claudeCode, now: clock) != nil)
  }

  /// And the same ten turns on a host that is behaving, which must stay silent.
  @Test("a working Stop event shows up as nothing at all")
  func workingStop() {
    var store = SessionStore(staleAfter: 300)
    var health = HookHealth()
    var clock = Timestamp.now

    for _ in 0..<10 {
      store.apply(AgentEvent(agent: .claudeCode, sessionID: "s", state: .working), now: clock)
      clock = clock.advanced(by: 30)
      store.apply(
        AgentEvent(agent: .claudeCode, sessionID: "s", state: .idle, event: "Stop"), now: clock)
      clock = clock.advanced(by: 400)
      health.record(expired: store.prune(now: clock), now: clock)
    }

    let verdict = health.verdict(for: .claudeCode, now: clock)
    #expect(verdict.endings == 10)
    #expect(verdict.timeouts == 0)
    #expect(health.warning(for: .claudeCode, now: clock) == nil)
  }
}
