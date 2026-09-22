import Foundation

/// What an agent is doing right now.
///
/// Hooks report lifecycle events; we collapse those into three states because
/// that is all the wake decision needs to know.
public enum AgentState: String, Codable, Sendable, CaseIterable {
  /// Mid-task. This is the only state that justifies holding the Mac awake.
  case working
  /// Blocked on the user — a permission prompt, a question. The task is not
  /// finished, but nothing is progressing either.
  case waiting
  /// Nothing in flight.
  case idle
}

/// Which tool produced an event. Raw strings rather than an enum: a new agent
/// should be able to post events without us shipping a release first.
public struct AgentKind: RawRepresentable, Codable, Sendable, Hashable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let claudeCode = AgentKind(rawValue: "claude-code")
  public static let codex = AgentKind(rawValue: "codex")
  public static let cursor = AgentKind(rawValue: "cursor")
  public static let gemini = AgentKind(rawValue: "gemini")
  public static let opencode = AgentKind(rawValue: "opencode")
}

/// One lifecycle report from an agent hook.
public struct AgentEvent: Codable, Sendable, Equatable {
  public let agent: AgentKind
  public let sessionID: String
  public let state: AgentState
  /// The host's own event name (`PostToolUse`, `Notification`, …). Kept verbatim
  /// for diagnostics; the wake decision only ever reads `state`.
  public let event: String?
  public let pid: Int32?
  public let cwd: String?
  /// First line of the user's prompt, when the host provides one.
  public let title: String?

  public init(
    agent: AgentKind,
    sessionID: String,
    state: AgentState,
    event: String? = nil,
    pid: Int32? = nil,
    cwd: String? = nil,
    title: String? = nil
  ) {
    self.agent = agent
    self.sessionID = sessionID
    self.state = state
    self.event = event
    self.pid = pid
    self.cwd = cwd
    self.title = title
  }

  private enum CodingKeys: String, CodingKey {
    case agent
    case sessionID = "session_id"
    case state
    case event
    case pid
    case cwd
    case title
  }
}

extension AgentEvent {
  /// Decode a hook payload.
  ///
  /// Hooks are shell scripts assembling JSON by hand, so payloads are assumed
  /// hostile: unknown agents are accepted, but a missing session id or an
  /// unrecognised state is rejected rather than guessed at.
  public static func decode(from data: Data) throws -> AgentEvent {
    try JSONDecoder().decode(AgentEvent.self, from: data)
  }
}
