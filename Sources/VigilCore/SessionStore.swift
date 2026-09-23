import Foundation

/// Which session, on which agent.
///
/// Two hosts hand out session ids from their own namespaces and nothing stops
/// them colliding — Codex and Cursor both use bare UUIDs, and a hook that falls
/// back to `pid-NNNN` collides outright. Keyed on the id alone, two live
/// sessions collapsed into one row attributed to whichever agent reported
/// first, and stopping one released the hold the other still needed.
public struct SessionKey: Sendable, Hashable {
  public let agent: AgentKind
  public let sessionID: String

  public init(agent: AgentKind, sessionID: String) {
    self.agent = agent
    self.sessionID = sessionID
  }
}

/// A single agent session we are tracking.
public struct AgentSession: Sendable, Equatable, Identifiable {
  public let agent: AgentKind
  /// The id the host gave us. Unique only within that host.
  public let sessionID: String
  public private(set) var state: AgentState
  /// When we last heard from this session. Read `wall` to show it, `uptime` to
  /// decide whether it has gone quiet.
  public private(set) var lastSeen: Timestamp
  public private(set) var startedAt: Timestamp
  public private(set) var cwd: String?
  public private(set) var title: String?
  public private(set) var pid: Int32?
  /// The host's own name for the last event we heard — `PostToolUse`, `Stop`,
  /// `StopFailure`. Kept because `state` alone cannot tell a turn that finished
  /// from one that stopped: both arrive as `idle`, and only the name says which.
  public private(set) var lastEvent: String?

  /// Unique across agents, so two hosts using the same session id stay two
  /// rows. The separator is a unit separator rather than a dash because a
  /// session id may legitimately contain one.
  public var id: String { "\(agent.rawValue)\u{1F}\(sessionID)" }

  public var key: SessionKey { SessionKey(agent: agent, sessionID: sessionID) }

  init(event: AgentEvent, now: Timestamp) {
    self.agent = event.agent
    self.sessionID = event.sessionID
    self.state = event.state
    self.lastSeen = now
    self.startedAt = now
    self.cwd = event.cwd
    self.title = event.title
    self.pid = event.pid
    self.lastEvent = event.event
  }

  mutating func apply(_ event: AgentEvent, now: Timestamp) {
    state = event.state
    lastSeen = now
    // Hooks only carry these on some events; never clear a value we already have.
    if let cwd = event.cwd, !cwd.isEmpty { self.cwd = cwd }
    if let title = event.title, !title.isEmpty { self.title = title }
    if let pid = event.pid { self.pid = pid }
    // Same rule, and the same reason: a host that sends no name leaves the last
    // one we had rather than blanking it. It fails towards `finished`, which is
    // the reading Vigil had before it could tell the two apart at all.
    if let name = event.event, !name.isEmpty { lastEvent = name }
  }

  /// How long this session has been tracked.
  public func age(now: Timestamp) -> TimeInterval { now.seconds(since: startedAt) }

  /// How long since it last reported anything.
  public func quietFor(now: Timestamp) -> TimeInterval { now.seconds(since: lastSeen) }
}

/// How a session's work ended.
///
/// Three outcomes, not two, because "the agent is no longer working" is not one
/// fact. A turn that reported `Stop`, a turn that reported `StopFailure`, and a
/// turn nobody ever reported anything about are three different things to tell
/// somebody who walked away, and collapsing them is how an app ends up chiming
/// "finished" at a run that died on a context overflow at 2am.
///
/// Ordered by how sure we are, least sure last, so the outcome of a whole run
/// is the `max` of its sessions'. A run with one clean ending and one session
/// that vanished is a run Vigil cannot vouch for, and saying so is the only
/// honest thing left: one good ending does not redeem the rest.
public enum SessionOutcome: Sendable, Equatable, Comparable, CaseIterable {
  /// The host said the turn was over, on an event that means it finished.
  case finished
  /// The host said the turn was over, on an event that means it did not finish
  /// — Claude Code's `StopFailure`, Codex's `Interrupt`. We know it stopped and
  /// we know it stopped early.
  case endedBadly
  /// Nobody said anything. The session ran out the staleness window still
  /// working or still waiting, so the last thing we know is that it was alive:
  /// the host crashed, the terminal closed, the Mac slept, or it is running
  /// this second and has simply stopped talking to us.
  case lostContact
}

extension SessionOutcome {
  /// Event names that end a turn without finishing it.
  ///
  /// Per host, not one flat set: these are names out of somebody else's
  /// vocabulary, and nothing stops the next host Vigil learns using `Interrupt`
  /// to mean something else entirely.
  ///
  /// This is the second place these two names appear — `AgentIntegration` lists
  /// them among each host's `idleEvents`, because they do end a turn and the
  /// hold has to be released for them. The duplication is deliberate: the other
  /// list answers "does this release the wake lock", this one answers "may
  /// Vigil tell the user their work is done", and a host could grow an event
  /// that is one and not the other. `SessionOutcomeTests` fails if a name here
  /// is not one that host actually sends, so the two cannot drift in silence.
  static let unfinishedEndings: [AgentKind: Set<String>] = [
    .claudeCode: ["StopFailure"],
    .codex: ["Interrupt"],
  ]
}

extension AgentSession {
  /// How this session's work ended, or nil while it is still live.
  ///
  /// `waiting` is live, deliberately. A session blocked on a permission prompt
  /// has not finished — the run is mid-sentence, waiting for a human — and
  /// treating it as over is what made every approval prompt announce that the
  /// agent had finished and the Mac could sleep.
  public var outcome: SessionOutcome? {
    switch state {
    case .working, .waiting:
      return nil
    case .idle:
      let unfinished = SessionOutcome.unfinishedEndings[agent] ?? []
      return unfinished.contains(lastEvent ?? "") ? .endedBadly : .finished
    }
  }

  /// Whether this session still counts as part of a run in flight.
  public var isLive: Bool { outcome == nil }
}

/// Tracks live agent sessions, built from hook events.
///
/// Deliberately not a class with timers: it is a value type driven by an
/// injected clock, so every expiry rule can be tested without waiting.
public struct SessionStore: Sendable {
  /// A session that stops reporting is presumed dead. Hosts crash, terminals get
  /// closed, and a session stuck in `.working` would hold the Mac awake forever.
  public var staleAfter: TimeInterval

  private var sessions: [SessionKey: AgentSession] = [:]

  public init(staleAfter: TimeInterval = 300) {
    self.staleAfter = staleAfter
  }

  @discardableResult
  public mutating func apply(_ event: AgentEvent, now: Timestamp = .now) -> AgentSession {
    let key = SessionKey(agent: event.agent, sessionID: event.sessionID)
    if var existing = sessions[key] {
      existing.apply(event, now: now)
      sessions[key] = existing
      return existing
    }
    let fresh = AgentSession(event: event, now: now)
    sessions[key] = fresh
    return fresh
  }

  /// Drop sessions that have gone quiet past `staleAfter`.
  @discardableResult
  public mutating func prune(now: Timestamp = .now) -> [AgentSession] {
    let dead = sessions.values.filter { $0.quietFor(now: now) > staleAfter }
    for session in dead { sessions.removeValue(forKey: session.key) }
    return dead
  }

  /// Live sessions, newest activity first.
  ///
  /// Ties break on `id` so the order is stable between renders — an unstable
  /// order makes SwiftUI animate rows that did not actually move.
  public func all(now: Timestamp = .now) -> [AgentSession] {
    sessions.values
      .filter { $0.quietFor(now: now) <= staleAfter }
      .sorted { a, b in
        if a.lastSeen.uptime != b.lastSeen.uptime { return a.lastSeen.uptime > b.lastSeen.uptime }
        return a.id < b.id
      }
  }

  public func active(now: Timestamp = .now) -> [AgentSession] {
    all(now: now).filter { $0.state == .working }
  }

  /// Sessions that are part of a run in flight — working, or stopped on a
  /// question for the human.
  ///
  /// `active` is the wake decision's question: is anything making progress, and
  /// should this Mac stay awake for it. This is the notification's: is the run
  /// over. They differ by exactly the sessions sitting at a permission prompt,
  /// and answering the second with the first is what made Vigil announce that
  /// the agent had finished and the Mac could sleep every time one asked to run
  /// a command.
  public func live(now: Timestamp = .now) -> [AgentSession] {
    all(now: now).filter(\.isLive)
  }

  /// Whether anything at all is tracked, stale rows included.
  ///
  /// Not "is anything live" — that question needs a clock, and every other
  /// reader here takes one. This is what `prune` leaves behind, and the only
  /// honest way to ask it without a `now` to measure against.
  public var isEmpty: Bool { sessions.isEmpty }
}
