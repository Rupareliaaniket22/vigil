import Foundation
import Testing

@testable import VigilCore

private let script = "/Users/x/.vigil/hooks/vigil-hook.sh"
private let other = "/opt/someone-else/their-hook.sh"

/// A settings file that already has a hook from another tool, plus unrelated keys.
private func existingSettings() -> [String: Any] {
  [
    "theme": "dark",
    "someOtherSetting": ["nested": true],
    "hooks": [
      "PreToolUse": [
        ["hooks": [["type": "command", "command": "\(other) PreToolUse"]]]
      ]
    ],
  ]
}

/// Reads commands out of either entry shape a host might use.
private func commands(_ settings: [String: Any], event: String) -> [String] {
  guard let hooks = settings["hooks"] as? [String: Any],
    let matchers = hooks[event] as? [[String: Any]]
  else { return [] }
  return matchers.flatMap { matcher -> [String] in
    if let flat = matcher["command"] as? String { return [flat] }
    return (matcher["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
  }
}

@Suite("Hook installation")
struct HookConfigurationTests {

  @Test("installs a hook for every event we listen for")
  func installsAllEvents() {
    let result = HookConfiguration.install(into: [:], scriptPath: script, integration: .claudeCode)
    for event in AgentIntegration.claudeCode.allEvents {
      let state = AgentIntegration.claudeCode.state(for: event)
      #expect(
        commands(result, event: event)
          .contains("'\(script)' claude-code \(event) \(state.rawValue)"))
    }
  }

  @Test("leaves unrelated settings untouched")
  func preservesUnrelatedKeys() {
    let result = HookConfiguration.install(
      into: existingSettings(), scriptPath: script, integration: .claudeCode)
    #expect(result["theme"] as? String == "dark")
    #expect((result["someOtherSetting"] as? [String: Any])?["nested"] as? Bool == true)
  }

  @Test("leaves another tool's hooks in place")
  func preservesForeignHooks() {
    let result = HookConfiguration.install(
      into: existingSettings(), scriptPath: script, integration: .claudeCode)
    let pre = commands(result, event: "PreToolUse")
    #expect(pre.contains("\(other) PreToolUse"))
    #expect(pre.contains { $0.contains(script) })
  }

  /// Every agent, not just Claude Code. Pinned to the nested shape, this
  /// missed Cursor's flat entries entirely — which is how Cursor ended up
  /// duplicating its hooks on every install.
  @Test("installing twice does not duplicate anything", arguments: AgentIntegration.all)
  func installIsIdempotent(integration: AgentIntegration) {
    let once = HookConfiguration.install(
      into: existingSettings(), scriptPath: script, integration: integration)
    let twice = HookConfiguration.install(into: once, scriptPath: script, integration: integration)
    for event in integration.allEvents {
      let ours = commands(twice, event: event).filter { $0.contains(script) }
      #expect(ours.count == 1, "\(integration.displayName) duplicated its hook for \(event)")
    }
  }

  @Test(
    "a moved app replaces its old hook rather than adding beside it",
    arguments: AgentIntegration.all)
  func replacesStalePath(integration: AgentIntegration) {
    let old = "/Applications/Vigil.app/hooks/vigil-hook.sh"
    let installed = HookConfiguration.install(
      into: [:], scriptPath: old, integration: integration)
    let moved = HookConfiguration.install(
      into: installed, scriptPath: script, integration: integration)

    for event in integration.allEvents {
      let ours = commands(moved, event: event)
      #expect(ours.contains { $0.contains(script) }, "\(integration.displayName): \(event)")
      #expect(
        !ours.contains { $0.contains(old) },
        "\(integration.displayName) kept its old path for \(event)")
    }
  }

  @Test("uninstall removes ours and keeps theirs")
  func uninstallIsSurgical() {
    let installed = HookConfiguration.install(
      into: existingSettings(), scriptPath: script, integration: .claudeCode)
    let removed = HookConfiguration.uninstall(from: installed, scriptPath: script)

    let pre = commands(removed, event: "PreToolUse")
    #expect(pre == ["\(other) PreToolUse"])
    #expect(removed["theme"] as? String == "dark")
  }

  @Test("uninstall leaves no empty scaffolding behind")
  func uninstallPrunes() {
    let installed = HookConfiguration.install(
      into: ["theme": "dark"], scriptPath: script, integration: .claudeCode)
    let removed = HookConfiguration.uninstall(from: installed, scriptPath: script)
    #expect(removed["hooks"] == nil, "an empty hooks object was left behind")
    #expect(removed["theme"] as? String == "dark")
  }

  @Test("uninstalling when never installed changes nothing")
  func uninstallIsSafeWhenAbsent() {
    let before = existingSettings()
    let after = HookConfiguration.uninstall(from: before, scriptPath: script)
    #expect(commands(after, event: "PreToolUse") == ["\(other) PreToolUse"])
  }

  /// Vigil's event set shrinks as well as grows, and the add loop only ever
  /// visits events we still want — so an entry for a retired event was never
  /// touched again. For Cursor's permission hooks that meant an install from an
  /// older version went on blocking every shell command forever, which is
  /// precisely the thing retiring them was meant to stop.
  @Test("reinstalling sweeps out hooks for events we no longer register")
  func retiredEventsAreSwept() {
    let retired = AgentIntegration(
      id: .cursor,
      displayName: "Cursor",
      settingsPath: ".cursor/hooks.json",
      workingEvents: ["beforeShellExecution", "afterFileEdit"],
      idleEvents: ["stop"],
      entryFormat: .flat
    )
    let old = HookConfiguration.install(
      into: ["hooks": ["beforeShellExecution": [["command": "\(other) beforeShellExecution"]]]],
      scriptPath: script, integration: retired)
    #expect(commands(old, event: "beforeShellExecution").contains { $0.contains(script) })

    let current = HookConfiguration.install(
      into: old, scriptPath: script, integration: .cursor)

    #expect(
      !commands(current, event: "beforeShellExecution").contains { $0.contains(script) },
      "a retired hook was left armed in the user's settings")
    #expect(
      commands(current, event: "beforeShellExecution") == ["\(other) beforeShellExecution"],
      "the sweep took another tool's hook with it")
    for event in AgentIntegration.cursor.allEvents {
      #expect(
        commands(current, event: event).filter { $0.contains(script) }.count == 1,
        "\(event) should have exactly one of ours after the sweep")
    }
  }

  /// "Never drop a setting we don't understand" applied only to keys outside
  /// `hooks`. Inside it, a value that was not the shape we expected read as an
  /// empty slot and got written over — so installing Vigil silently deleted
  /// another tool's hook.
  @Test("a hook entry in a shape we don't recognise is left alone, not replaced")
  func doesNotOverwriteShapesItCannotRead() {
    let theirs: [String: Any] = [
      "version": 1,
      "hooks": ["Stop": ["command": "\(other) Stop"]],
    ]
    let result = HookConfiguration.install(
      into: theirs, scriptPath: script, integration: .claudeCode)
    let stop = (result["hooks"] as? [String: Any])?["Stop"] as? [String: Any]
    #expect(stop?["command"] as? String == "\(other) Stop", "their hook was overwritten")
    #expect(
      HookConfiguration.unmergeableKeys(in: theirs, integration: .claudeCode) == ["Stop"],
      "the installer has to be able to name what it refused")
    // Everything else still installs, so the refusal is about one entry rather
    // than the whole file.
    #expect(commands(result, event: "PreToolUse").contains { $0.contains(script) })
  }

  @Test("a hooks container in a shape we don't recognise leaves the file untouched")
  func doesNotOverwriteAnAlienHooksKey() {
    let theirs: [String: Any] = ["theme": "dark", "hooks": "run-all-my-hooks.sh"]
    let result = HookConfiguration.install(
      into: theirs, scriptPath: script, integration: .gemini)
    #expect(result["hooks"] as? String == "run-all-my-hooks.sh", "their hooks key was replaced")
    #expect(HookConfiguration.unmergeableKeys(in: theirs, integration: .gemini) == ["hooks"])
  }

  /// `"hooks": null` is a file with nothing in it to protect, but `NSNull` is
  /// not nil, so the guard above would have refused to install into it.
  @Test("a null hooks key is an absent one")
  func nullHooksIsNotAnObstacle() {
    let settings: [String: Any] = ["hooks": NSNull()]
    #expect(HookConfiguration.unmergeableKeys(in: settings, integration: .codex).isEmpty)
    let result = HookConfiguration.install(
      into: settings, scriptPath: script, integration: .codex)
    #expect(commands(result, event: "Stop").contains { $0.contains(script) })
  }

  @Test("a file shaped the way its host documents has nothing unmergeable")
  func ordinarySettingsAreMergeable() {
    for integration in AgentIntegration.all {
      #expect(HookConfiguration.unmergeableKeys(in: [:], integration: integration).isEmpty)
      #expect(
        HookConfiguration.unmergeableKeys(in: existingSettings(), integration: integration)
          .isEmpty)
      let installed = HookConfiguration.install(
        into: existingSettings(), scriptPath: script, integration: integration)
      #expect(
        HookConfiguration.unmergeableKeys(in: installed, integration: integration).isEmpty,
        "\(integration.displayName) cannot re-merge into what it just wrote")
    }
  }

  @Test("detects whether we are installed")
  func detectsInstallation() {
    #expect(!HookConfiguration.isInstalled(in: [:], scriptPath: script, integration: .claudeCode))
    #expect(
      !HookConfiguration.isInstalled(
        in: existingSettings(), scriptPath: script, integration: .claudeCode))

    let installed = HookConfiguration.install(
      into: existingSettings(), scriptPath: script, integration: .claudeCode)
    #expect(
      HookConfiguration.isInstalled(in: installed, scriptPath: script, integration: .claudeCode))

    let removed = HookConfiguration.uninstall(from: installed, scriptPath: script)
    #expect(
      !HookConfiguration.isInstalled(in: removed, scriptPath: script, integration: .claudeCode))
  }

}

@Suite("Agent integrations")
struct AgentIntegrationTests {

  /// The idle third of this used to be unfalsifiable: `state(for:)` answers
  /// `.idle` for anything it does not recognise, so an empty `idleEvents` —
  /// or one missing the event that actually ends a turn — passed every
  /// assertion. That is precisely how Claude Code's `Stop` went missing
  /// without a test noticing. What is checked now is that the three sets
  /// really are three sets: named, non-empty where they must be, and disjoint.
  @Test("each agent's events map to the right state", arguments: AgentIntegration.all)
  func eventsMapCorrectly(integration: AgentIntegration) {
    #expect(!integration.workingEvents.isEmpty, "\(integration.displayName) reports no work")
    #expect(
      !integration.idleEvents.isEmpty,
      "\(integration.displayName) has no event meaning stopped, so sessions only ever expire")

    for event in integration.workingEvents {
      #expect(integration.state(for: event) == .working, "\(event) should be working")
    }
    for event in integration.waitingEvents {
      #expect(integration.state(for: event) == .waiting, "\(event) should be waiting")
    }
    for event in integration.idleEvents {
      #expect(integration.state(for: event) == .idle, "\(event) should be idle")
      // The real assertion: it is idle because we said so, not because
      // `state(for:)` fell through to its default.
      #expect(
        !integration.workingEvents.contains(event) && !integration.waitingEvents.contains(event),
        "\(event) is in two categories at once")
    }

    #expect(
      Set(integration.allEvents).count == integration.allEvents.count,
      "\(integration.displayName) lists an event twice, so it installs two hooks for it")
  }

  /// A deliberate golden master.
  ///
  /// Every name here is one a host actually emits, established from a real
  /// config file rather than guessed. Pinning the set means dropping one — the
  /// way `Stop` was dropped, so every finished Claude Code turn held the Mac
  /// awake until it went stale — fails here instead of a release later. Adding
  /// one is also a deliberate edit: it changes what `isInstalled` demands, so
  /// every existing install becomes out of date and has to be re-run.
  @Test("the event vocabulary only changes on purpose")
  func eventVocabularyIsPinned() {
    let expected: [AgentKind: Set<String>] = [
      .claudeCode: [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
        "Notification", "PermissionRequest", "Elicitation", "Stop", "StopFailure", "SessionEnd",
      ],
      .codex: [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt",
        "SessionEnd",
      ],
      .gemini: [
        "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd",
      ],
      .cursor: [
        "afterShellExecution", "afterFileEdit", "afterMCPExecution", "afterAgentThought",
        "afterAgentResponse", "stop", "sessionEnd",
      ],
    ]
    for integration in AgentIntegration.all {
      #expect(
        Set(integration.allEvents) == expected[integration.id],
        "\(integration.displayName)'s event set changed")
    }
  }

  /// The bug that keeps coming back has one shape: a turn ends by a route
  /// Vigil is not listening on, so nothing says idle and the hold runs out the
  /// staleness window instead — five minutes of holding the Mac awake for work
  /// that finished. `Stop` was the first. These are the others, one host at a
  /// time: the error exit, the interrupt, the terminal closing.
  ///
  /// Not a restatement of the golden master above. That one notices any change;
  /// this one says which changes are the dangerous ones and why, so removing
  /// `StopFailure` fails with a sentence about failed turns rather than a set
  /// mismatch.
  @Test("every way a turn can end is listened for")
  func everyTurnEndingIsCovered() {
    let endings: [AgentKind: Set<String>] = [
      // Stop ends a good turn, StopFailure a turn that errored, SessionEnd the
      // whole session.
      .claudeCode: ["Stop", "StopFailure", "SessionEnd"],
      // Interrupt is the user pressing escape.
      .codex: ["Stop", "Interrupt", "SessionEnd"],
      // Gemini's AfterAgent fires whenever the agent loop ends, however it ended.
      .gemini: ["AfterAgent", "SessionEnd"],
      .cursor: ["afterAgentResponse", "stop", "sessionEnd"],
    ]
    for integration in AgentIntegration.all {
      let missing = (endings[integration.id] ?? []).subtracting(integration.idleEvents)
      let dropped = missing.sorted().joined(separator: ", ")
      #expect(
        missing.isEmpty,
        """
        \(integration.displayName) stopped listening for \(dropped) — a turn that \
        ends that way holds the Mac awake until the session goes stale
        """)
    }
  }

  /// Cursor blocks the action when a permission hook returns anything it can't
  /// parse, and empty output is one of those things. Vigil's hook writes
  /// nothing, so being registered on one of these meant every shell command,
  /// file read, MCP call and prompt in Cursor was blocked by a wake-lock hook.
  ///
  /// The list is spelled out rather than derived, because the way this comes
  /// back is somebody adding `beforeSubmitPrompt` for the prompt text it
  /// carries — which is a real thing to want, and still not worth putting
  /// Vigil in the way of the user's own prompt.
  @Test("Vigil registers on no hook its host waits on for a verdict")
  func staysOutOfThePermissionPath() {
    let verdictHooks: [AgentKind: Set<String>] = [
      .cursor: [
        "beforeShellExecution", "beforeReadFile", "beforeMCPExecution", "beforeSubmitPrompt",
        "beforeTabFileRead", "preToolUse", "subagentStart",
      ]
    ]
    for integration in AgentIntegration.all {
      let offending = (verdictHooks[integration.id] ?? []).intersection(integration.allEvents)
      let names = offending.sorted().joined(separator: ", ")
      #expect(
        offending.isEmpty,
        """
        \(integration.displayName) registers on \(names), which the host waits on for a \
        verdict. Vigil's hook prints nothing, and nothing is a block
        """)
    }
  }

  /// Not a wish: a record of which hosts can tell us they are blocked on the
  /// human. Three of the four do, and for two of them Vigil spent a long time
  /// asserting the opposite — Gemini CLI's `Notification` and Codex's
  /// `PermissionRequest` were both there to be read, so a session of either
  /// sitting on a permission prompt held the Mac awake until it went stale.
  ///
  /// Cursor is the remaining gap, and inventing an event name to paper over it
  /// would install a hook nothing ever fires.
  @Test("only the hosts that publish a blocked-on-user event claim one")
  func blockedOnUserIsHonest() {
    for integration in [AgentIntegration.claudeCode, .codex, .gemini] {
      #expect(
        integration.hasBlockedOnUserEvent,
        "\(integration.displayName) stopped listening for its blocked-on-user event")
    }
    #expect(
      !AgentIntegration.cursor.hasBlockedOnUserEvent,
      "Cursor now claims a waiting event — check the host really emits it")
  }

  /// The event each host publishes when it stops to ask, pinned by name.
  ///
  /// `hasBlockedOnUserEvent` above only counts; this says which, because the
  /// three names came from three different places and each one is a claim
  /// about somebody else's source that a reader should be able to check.
  @Test("the blocked-on-user events are the ones the hosts actually publish")
  func blockedOnUserEventsAreNamed() {
    // Claude Code: `Notification` (open set, kept as a backstop),
    // `PermissionRequest` ("When a permission dialog is displayed") and
    // `Elicitation` ("When an MCP server requests user input").
    #expect(
      Set(AgentIntegration.claudeCode.waitingEvents)
        == ["Notification", "PermissionRequest", "Elicitation"])
    // Codex: `HookEventName::PermissionRequest`, stage one of
    // `Session::request_approval`, ahead of Guardian and ahead of the user.
    #expect(AgentIntegration.codex.waitingEvents == ["PermissionRequest"])
    // Gemini CLI: `HookEventName.Notification`, whose only payload type is
    // `NotificationType.ToolPermission`, fired from `notifyHooks` on the line
    // before the prompt goes up.
    #expect(AgentIntegration.gemini.waitingEvents == ["Notification"])
  }

  /// Claude Code cannot tell us the user pressed escape, and that is the
  /// single most common way a turn ends.
  ///
  /// There is no `Interrupt` in its thirty-three-name catalogue, and every
  /// main-turn `Stop` dispatch is handed the turn's own abort signal, which the
  /// hook runner checks before it runs anything. `StopFailure` covers the API
  /// errors, not this. If somebody adds an event name here to close the gap it
  /// had better be one Claude Code really sends, and if Claude Code ever ships
  /// an interrupt event this test is where the good news lands.
  @Test("a host that cannot report an interrupt says so")
  func interruptCoverageIsHonest() {
    #expect(
      !AgentIntegration.claudeCode.hasInterruptEvent,
      "Claude Code now claims an interrupt event — check its hook catalogue really has one")
    #expect(AgentIntegration.codex.hasInterruptEvent)
    #expect(AgentIntegration.codex.interruptEvent == "Interrupt")
    // Whatever a host names its interrupt, it has to be an ending: the hold is
    // released on `idleEvents` and nothing else.
    for integration in AgentIntegration.all {
      guard let event = integration.interruptEvent else { continue }
      #expect(
        integration.idleEvents.contains(event),
        "\(integration.displayName)'s interrupt event is not in its idle events")
    }
  }

  /// The end-to-end shape of the blocked-on-user fix: an event arrives from a
  /// host, and the Mac is allowed to sleep because nobody is at the keyboard.
  ///
  /// Reading these three names as `working` was the bug — a Gemini or Codex
  /// session parked on a permission prompt held the Mac awake for the whole
  /// staleness window. Reading an unregistered name as `idle`, which is what
  /// `state(for:)` does with anything it has not been told about, is the other
  /// half: it would have announced the run finished. `waiting` is neither.
  @Test(
    "a session stopped on a permission prompt neither holds nor finishes",
    arguments: [
      (AgentKind.gemini, "Notification"),
      (.codex, "PermissionRequest"),
      (.claudeCode, "PermissionRequest"),
      (.claudeCode, "Elicitation"),
    ])
  func aPromptIsWaitingNotWorking(agent: AgentKind, event: String) {
    let integration = AgentIntegration.all.first { $0.id == agent }!
    #expect(integration.state(for: event) == .waiting)

    var store = SessionStore()
    store.apply(AgentEvent(agent: agent, sessionID: "s", state: .working, event: "PreToolUse"))
    let asked = store.apply(
      AgentEvent(agent: agent, sessionID: "s", state: integration.state(for: event), event: event))

    let decision = WakePolicy.decide(
      sessions: [asked], conditions: PowerConditions(), settings: WakeSettings())
    #expect(!decision.holdIdleAssertion, "nobody is there, so the Mac may sleep")
    // Still part of the run: the turn is mid-sentence, not over, so this must
    // not read as an agent that finished.
    #expect(asked.isLive)
    #expect(asked.outcome == nil)
  }

  /// Claude Code fires `SubagentStop` even on a turn the user escaped out of —
  /// the teardown path passes no abort signal, so it survives the abort that
  /// kills `Stop`. That makes it tempting as a stand-in for the missing
  /// interrupt, and it must not be used as one: in every other case it means
  /// one `Agent` call finished and the parent turn continues, so reading it as
  /// an ending would drop the hold in the middle of a run.
  @Test("SubagentStop means the parent turn continues")
  func subagentStopIsStillWork() {
    #expect(AgentIntegration.claudeCode.state(for: "SubagentStop") == .working)
  }

  /// Codex re-fires `SessionStart` in the middle of a turn.
  ///
  /// `SessionStartSource` is `{Startup, Resume, Clear, Compact, Fork}`, and
  /// `Session::compact` queues the `Compact` one as its last act. The turn loop
  /// drains that queue with `run_pending_session_start_hooks` immediately after
  /// `run_auto_compact(…, CompactionPhase::MidTurn)` and immediately before it
  /// continues — so a long run that hits its context limit fired `SessionStart`
  /// while still working, and Vigil dropped the hold for the whole
  /// post-compaction round trip.
  @Test("Codex's SessionStart is not treated as an ending")
  func codexSessionStartIsNotIdle() {
    #expect(
      !AgentIntegration.codex.allEvents.contains("SessionStart"),
      """
      Codex fires SessionStart mid-turn after a compaction, so registering for it \
      drops the wake hold across the slowest request in the session
      """)
  }

  @Test("agents are named for people, not by their event vocabulary")
  func agentsHaveDisplayNames() {
    #expect(AgentIntegration.displayName(for: .claudeCode) == "Claude Code")
    #expect(AgentIntegration.displayName(for: .gemini) == "Gemini CLI")
    // An agent we ship no integration for still gets a name to show.
    #expect(AgentIntegration.displayName(for: AgentKind(rawValue: "aider")) == "aider")
  }

  @Test("an unrecognised event is treated as idle, never as work")
  func unknownEventIsIdle() {
    // Guessing "working" would let a mislabelled hook pin the Mac awake.
    #expect(AgentIntegration.claudeCode.state(for: "SomethingNewApple Added") == .idle)
  }

  @Test("the mapping is baked into the installed command", arguments: AgentIntegration.all)
  func mappingIsBakedIn(integration: AgentIntegration) {
    let result = HookConfiguration.install(
      into: [:], scriptPath: script, integration: integration)

    for event in integration.allEvents {
      let expected =
        "'\(script)' \(integration.id.rawValue) \(event) \(integration.state(for: event).rawValue)"
      #expect(commands(result, event: event).contains(expected))
    }
  }

  @Test("Gemini carries the per-hook timeout its config expects")
  func geminiTimeout() {
    let result = HookConfiguration.install(into: [:], scriptPath: script, integration: .gemini)
    let hooks = result["hooks"] as? [String: Any] ?? [:]
    let matchers = hooks["AfterAgent"] as? [[String: Any]] ?? []
    let entries = matchers.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    #expect(entries.contains { $0["timeout"] as? Int == 10_000 })
  }

  @Test("Claude Code carries no timeout, because its config does not use one")
  func claudeCodeHasNoTimeout() {
    let result = HookConfiguration.install(into: [:], scriptPath: script, integration: .claudeCode)
    let hooks = result["hooks"] as? [String: Any] ?? [:]
    let matchers = hooks["PreToolUse"] as? [[String: Any]] ?? []
    let entries = matchers.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    // `allSatisfy` on an empty collection is true, so without this the whole
    // test passed just as happily if PreToolUse stopped being installed at all.
    #expect(!entries.isEmpty, "nothing was installed, so the assertion below proves nothing")
    #expect(entries.allSatisfy { $0["timeout"] == nil })
  }

  @Test("agents write to their own settings files")
  func distinctSettingsPaths() {
    let paths = Set(AgentIntegration.all.map(\.settingsPath))
    #expect(paths.count == AgentIntegration.all.count)
  }
}

@Suite("Hook entry shapes")
struct HookEntryFormatTests {

  @Test("Cursor gets the flat shape its config uses")
  func cursorIsFlat() {
    let result = HookConfiguration.install(into: [:], scriptPath: script, integration: .cursor)
    let hooks = result["hooks"] as? [String: Any] ?? [:]
    let matchers = hooks["stop"] as? [[String: Any]] ?? []

    #expect(matchers.count == 1)
    // Flat: the command sits directly on the entry, with no "hooks" wrapper.
    #expect(matchers.first?["command"] as? String != nil)
    #expect(matchers.first?["hooks"] == nil)
  }

  @Test("the others get the nested shape")
  func othersAreNested() {
    for integration in [AgentIntegration.claudeCode, .codex, .gemini] {
      let result = HookConfiguration.install(
        into: [:], scriptPath: script, integration: integration)
      let hooks = result["hooks"] as? [String: Any] ?? [:]
      let event = integration.allEvents[0]
      let matchers = hooks[event] as? [[String: Any]] ?? []

      #expect(matchers.first?["hooks"] != nil, "\(integration.displayName) should be nested")
      #expect(matchers.first?["command"] == nil, "\(integration.displayName) should not be flat")
    }
  }

  @Test("uninstall recognises our entries in both shapes")
  func uninstallHandlesBothShapes() {
    for integration in AgentIntegration.all {
      let installed = HookConfiguration.install(
        into: ["version": 1], scriptPath: script, integration: integration)
      let removed = HookConfiguration.uninstall(from: installed, scriptPath: script)

      #expect(removed["hooks"] == nil, "\(integration.displayName) left scaffolding behind")
      #expect(removed["version"] as? Int == 1, "\(integration.displayName) dropped a settings key")
    }
  }

  @Test("Cursor's foreign hooks survive, in their own shape")
  func cursorPreservesForeignHooks() {
    let existing: [String: Any] = [
      "version": 1,
      "hooks": ["stop": [["command": "/opt/other/their-hook.sh stop"]]],
    ]
    let installed = HookConfiguration.install(
      into: existing, scriptPath: script, integration: .cursor)
    let stop = commands(installed, event: "stop")

    #expect(stop.contains("/opt/other/their-hook.sh stop"))
    #expect(stop.contains { $0.contains(script) })

    let removed = HookConfiguration.uninstall(from: installed, scriptPath: script)
    #expect(commands(removed, event: "stop") == ["/opt/other/their-hook.sh stop"])
  }
}
