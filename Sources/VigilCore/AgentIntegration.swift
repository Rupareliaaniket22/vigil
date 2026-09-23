import Foundation

/// How a host shapes a hook entry in its settings file.
public enum HookEntryFormat: Sendable, Equatable {
  /// `"event": [ { "hooks": [ { "type": "command", "command": "…" } ] } ]`
  /// — Claude Code, Codex, Gemini CLI.
  case nested
  /// `"event": [ { "command": "…" } ]` — Cursor.
  case flat
}

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
  ///
  /// Empty for every host but Claude Code, and not an oversight: Codex, Gemini
  /// CLI and Cursor publish no lifecycle event for "asking the human". Until
  /// one of them does, a session of theirs sitting on a permission prompt reads
  /// as `working` until it goes stale. Guessing at an event name would be
  /// worse — see `hasBlockedOnUserEvent`.
  public let waitingEvents: [String]
  /// Events that mean it has stopped.
  public let idleEvents: [String]
  /// Some hosts want a per-hook timeout in their config.
  public let timeoutMilliseconds: Int?
  /// Hosts do not agree on the shape of a hook entry.
  public let entryFormat: HookEntryFormat

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

  /// Whether this host tells us when it is blocked on the human.
  ///
  /// False means a session of this agent sitting on a permission prompt counts
  /// as `working` until it goes stale — the hold outlives the work by up to the
  /// staleness window. Recorded rather than hidden so the gap is visible in one
  /// place instead of reading as an empty array someone forgot to fill in.
  public var hasBlockedOnUserEvent: Bool { !waitingEvents.isEmpty }

  public init(
    id: AgentKind,
    displayName: String,
    settingsPath: String,
    scriptName: String,
    workingEvents: [String],
    waitingEvents: [String] = [],
    idleEvents: [String],
    timeoutMilliseconds: Int? = nil,
    entryFormat: HookEntryFormat = .nested
  ) {
    self.id = id
    self.displayName = displayName
    self.settingsPath = settingsPath
    self.scriptName = scriptName
    self.workingEvents = workingEvents
    self.waitingEvents = waitingEvents
    self.idleEvents = idleEvents
    self.timeoutMilliseconds = timeoutMilliseconds
    self.entryFormat = entryFormat
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
    // `Stop` ends a turn; `SessionEnd` only fires when the whole session goes
    // away. Without `Stop`, every finished turn held the Mac awake until the
    // session went stale.
    //
    // `StopFailure` is the same event for a turn that ended badly — an API
    // error, a context overflow, a tool call that could not be parsed. Claude
    // Code dispatches it from its own code path (`executeStopFailureHooks`),
    // on the early returns out of the query loop, so a turn that fails is a
    // turn `Stop` never hears about. That is the missing-`Stop` bug wearing a
    // different name, and it was live: of 76 turns in one afternoon's hook
    // trace, 33 ended with no idle event at all, each holding the Mac awake
    // for the full staleness window afterwards. Listed even though `Stop` may
    // also fire on some of those paths — both mean idle, so an overlap costs
    // one redundant event and the gap costs five minutes.
    idleEvents: ["Stop", "StopFailure", "SessionEnd"]
  )

  public static let codex = AgentIntegration(
    id: .codex,
    displayName: "Codex",
    settingsPath: ".codex/hooks.json",
    scriptName: "vigil-codex-hook",
    workingEvents: ["UserPromptSubmit", "PreToolUse", "PostToolUse"],
    // SessionStart means a session opened, not that work began.
    //
    // `Interrupt` and `SessionEnd` are the two ways a Codex turn ends without
    // `Stop`: the user presses escape, or the terminal goes away mid-tool. Both
    // left the session reading `working` until it went stale — the same shape
    // as Claude Code's missing `Stop`, and the same five minutes of holding the
    // Mac awake for work that finished.
    idleEvents: ["SessionStart", "Stop", "Interrupt", "SessionEnd"]
  )

  public static let gemini = AgentIntegration(
    id: .gemini,
    displayName: "Gemini CLI",
    settingsPath: ".gemini/settings.json",
    scriptName: "vigil-gemini-hook",
    workingEvents: ["BeforeAgent", "BeforeTool", "AfterTool"],
    // A session that is torn down without a closing `AfterAgent` — the terminal
    // closed, the host crashed — would otherwise stay `working` until it went
    // stale.
    idleEvents: ["AfterAgent", "SessionEnd"],
    // Gemini's own config carries a per-hook timeout; match its convention.
    timeoutMilliseconds: 10_000
  )

  public static let cursor = AgentIntegration(
    id: .cursor,
    displayName: "Cursor",
    settingsPath: ".cursor/hooks.json",
    scriptName: "vigil-hook",
    // Every one of these is an *observing* hook. Cursor divides its events in
    // two, and the division is the whole reason this list looks the way it
    // does: `beforeShellExecution`, `beforeReadFile`, `beforeMCPExecution` and
    // `beforeSubmitPrompt` are permission hooks — Cursor reads their stdout for
    // a verdict, and documents that "invalid JSON or a response that doesn't
    // match the hook's schema blocks the action", empty output included. Vigil
    // writes nothing to stdout, so registering on those four meant every shell
    // command, file read, MCP call and prompt in Cursor was blocked by a menu
    // bar app's wake-lock hook.
    //
    // The fix is not to start answering. A wake-lock utility has no business
    // voting on whether an agent may run a command, and answering would make
    // Cursor's agent depend on this script being present, fast and correct.
    // Nothing is lost by standing aside: every `before*` is followed by the
    // `after*` twin that is already listed here.
    workingEvents: [
      "afterShellExecution", "afterFileEdit", "afterMCPExecution", "afterAgentThought",
    ],
    // afterAgentResponse closes a turn, so it means the agent has stopped.
    // sessionEnd is the teardown guard — the same one Gemini CLI needed.
    idleEvents: ["afterAgentResponse", "stop", "sessionEnd"],
    entryFormat: .flat
  )

  /// Every integration Vigil ships, in the order the settings window lists them.
  public static let all: [AgentIntegration] = [.claudeCode, .codex, .gemini, .cursor]

  /// What to call an agent in the interface.
  ///
  /// Events carry a raw kind, so a session can name an agent we ship no
  /// integration for. Falling back to the raw value keeps such a session
  /// visible — "claude-code" is still a better answer than nothing — but the
  /// four we know about read as their proper names, including to VoiceOver,
  /// which otherwise spells the hyphen out.
  public static func displayName(for kind: AgentKind) -> String {
    all.first { $0.id == kind }?.displayName ?? kind.rawValue
  }
}
