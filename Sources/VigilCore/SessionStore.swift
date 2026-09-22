import Foundation

/// A single agent session we are tracking.
public struct AgentSession: Sendable, Equatable, Identifiable {
  public let id: String
  public let agent: AgentKind
  public private(set) var state: AgentState
  public private(set) var lastSeen: Date
  public private(set) var startedAt: Date
  public private(set) var cwd: String?
  public private(set) var title: String?
  public private(set) var pid: Int32?

  init(event: AgentEvent, now: Date) {
    self.id = event.sessionID
    self.agent = event.agent
    self.state = event.state
    self.lastSeen = now
    self.startedAt = now
    self.cwd = event.cwd
    self.title = event.title
    self.pid = event.pid
  }

  mutating func apply(_ event: AgentEvent, now: Date) {
    state = event.state
    lastSeen = now
    // Hooks only carry these on some events; never clear a value we already have.
    if let cwd = event.cwd, !cwd.isEmpty { self.cwd = cwd }
    if let title = event.title, !title.isEmpty { self.title = title }
    if let pid = event.pid { self.pid = pid }
  }

  /// How long this session has been tracked.
  public func age(now: Date) -> TimeInterval { now.timeIntervalSince(startedAt) }
}

/// Tracks live agent sessions, built from hook events.
///
/// Deliberately not a class with timers: it is a value type driven by an
/// injected clock, so every expiry rule can be tested without waiting.
public struct SessionStore: Sendable {
  /// A session that stops reporting is presumed dead. Hosts crash, terminals get
  /// closed, and a session stuck in `.working` would hold the Mac awake forever.
  public var staleAfter: TimeInterval

  private var sessions: [String: AgentSession] = [:]

  public init(staleAfter: TimeInterval = 300) {
    self.staleAfter = staleAfter
  }

  @discardableResult
  public mutating func apply(_ event: AgentEvent, now: Date = Date()) -> AgentSession {
    if var existing = sessions[event.sessionID] {
      existing.apply(event, now: now)
      sessions[event.sessionID] = existing
      return existing
    }
    let fresh = AgentSession(event: event, now: now)
    sessions[event.sessionID] = fresh
    return fresh
  }

  /// Drop sessions that have gone quiet past `staleAfter`.
  @discardableResult
  public mutating func prune(now: Date = Date()) -> [AgentSession] {
    let dead = sessions.values.filter { now.timeIntervalSince($0.lastSeen) > staleAfter }
    for session in dead { sessions.removeValue(forKey: session.id) }
    return dead
  }

  public mutating func remove(sessionID: String) {
    sessions.removeValue(forKey: sessionID)
  }

  /// Live sessions, newest activity first.
  public func all(now: Date = Date()) -> [AgentSession] {
    sessions.values
      .filter { now.timeIntervalSince($0.lastSeen) <= staleAfter }
      .sorted { $0.lastSeen > $1.lastSeen }
  }

  public func active(now: Date = Date()) -> [AgentSession] {
    all(now: now).filter { $0.state == .working }
  }

  public var isEmpty: Bool { sessions.isEmpty }
}
