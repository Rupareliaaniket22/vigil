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
  }

  mutating func apply(_ event: AgentEvent, now: Timestamp) {
    state = event.state
    lastSeen = now
    // Hooks only carry these on some events; never clear a value we already have.
    if let cwd = event.cwd, !cwd.isEmpty { self.cwd = cwd }
    if let title = event.title, !title.isEmpty { self.title = title }
    if let pid = event.pid { self.pid = pid }
  }

  /// How long this session has been tracked.
  public func age(now: Timestamp) -> TimeInterval { now.seconds(since: startedAt) }

  /// How long since it last reported anything.
  public func quietFor(now: Timestamp) -> TimeInterval { now.seconds(since: lastSeen) }
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

  /// Whether anything at all is tracked, stale rows included.
  ///
  /// Not "is anything live" — that question needs a clock, and every other
  /// reader here takes one. This is what `prune` leaves behind, and the only
  /// honest way to ask it without a `now` to measure against.
  public var isEmpty: Bool { sessions.isEmpty }
}
