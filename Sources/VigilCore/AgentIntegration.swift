import Foundation

/// One agent Vigil knows how to wire itself into.
///
/// Each host names its lifecycle events differently and keeps its settings
/// somewhere different, but they all take the same shape of hook entry, so the
/// differences live in data rather than in a branch per agent.
public struct AgentIntegration: Sendable, Identifiable, Equatable {
  public let id: AgentKind
  /// What to call it in the interface.
  public let displayName: String
  /// Settings file, relative to the user's home directory.
  public let settingsPath: String
  /// Hook script name, as shipped in the app bundle.
  public let scriptName: String
  /// Events that mean the agent is mid-task.
  public let workingEvents: [String]
  /// Events that mean it is blocked on the user. Deliberately not a reason to
  /// hold the Mac awake — someone could be away for hours.
  public let waitingEvents: [String]
  /// Events that mean it has stopped.
  public let idleEvents: [String]
  /// Some hosts want a per-hook timeout in their config.
  public let timeoutMilliseconds: Int?

  public var allEvents: [String] { workingEvents + waitingEvents + idleEvents }

  /// What this host's event name means, in Vigil's terms.
  ///
  /// Anything unrecognised is treated as idle: assuming an unknown event means
  /// work would let a mislabelled hook hold the Mac awake indefinitely, which
  /// is the failure worth avoiding.
  public func state(for event: String) -> AgentState {
    if workingEvents.contains(event) { return .working }
    if waitingEvents.contains(event) { return .waiting }
    return .idle
  }

  public init(
    id: AgentKind,
    displayName: String,
    settingsPath: String,
    scriptName: String,
    workingEvents: [String],
    waitingEvents: [String] = [],
    idleEvents: [String],
    timeoutMilliseconds: Int? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.settingsPath = settingsPath
    self.scriptName = scriptName
    self.workingEvents = workingEvents
    self.waitingEvents = waitingEvents
    self.idleEvents = idleEvents
    self.timeoutMilliseconds = timeoutMilliseconds
  }
}

extension AgentIntegration {
  public static let claudeCode = AgentIntegration(
    id: .claudeCode,
    displayName: "Claude Code",
    settingsPath: ".claude/settings.json",
    scriptName: "vigil-hook",
    workingEvents: [
      "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
    ],
    waitingEvents: ["Notification"],
    idleEvents: ["SessionEnd"]
  )

  public static let codex = AgentIntegration(
    id: .codex,
    displayName: "Codex",
    settingsPath: ".codex/hooks.json",
    scriptName: "vigil-codex-hook",
    workingEvents: ["UserPromptSubmit", "PreToolUse", "PostToolUse"],
    idleEvents: ["SessionStart", "Stop"]
  )

  public static let gemini = AgentIntegration(
    id: .gemini,
    displayName: "Gemini CLI",
    settingsPath: ".gemini/settings.json",
    scriptName: "vigil-gemini-hook",
    workingEvents: ["BeforeAgent", "BeforeTool", "AfterTool"],
    idleEvents: ["AfterAgent"],
    // Gemini's own config carries a per-hook timeout; match its convention.
    timeoutMilliseconds: 10_000
  )

  /// Every integration Vigil ships, in the order the settings window lists them.
  public static let all: [AgentIntegration] = [.claudeCode, .codex, .gemini]
}
