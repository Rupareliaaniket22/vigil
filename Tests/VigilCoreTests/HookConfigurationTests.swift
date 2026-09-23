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
        "Notification", "Stop", "StopFailure", "SessionEnd",
      ],
      .codex: [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "SessionStart", "Stop", "Interrupt",
        "SessionEnd",
      ],
      .gemini: ["BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent", "SessionEnd"],
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
  /// human. Only Claude Code does. For the others a session sitting on a
  /// permission prompt reads as working until it goes stale, and inventing an
  /// event name to paper over that would install a hook nothing ever fires.
  @Test("only the hosts that publish a blocked-on-user event claim one")
  func blockedOnUserIsHonest() {
    #expect(AgentIntegration.claudeCode.hasBlockedOnUserEvent)
    for integration in [AgentIntegration.codex, .gemini, .cursor] {
      #expect(
        !integration.hasBlockedOnUserEvent,
        "\(integration.displayName) now claims a waiting event — check the host really emits it")
    }
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
