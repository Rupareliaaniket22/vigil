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
        "Notification", "Stop", "SessionEnd",
      ],
      .codex: ["UserPromptSubmit", "PreToolUse", "PostToolUse", "SessionStart", "Stop"],
      .gemini: ["BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent", "SessionEnd"],
      .cursor: [
        "beforeSubmitPrompt", "beforeShellExecution", "afterShellExecution", "beforeReadFile",
        "afterFileEdit", "beforeMCPExecution", "afterMCPExecution", "afterAgentThought",
        "afterAgentResponse", "stop",
      ],
    ]
    for integration in AgentIntegration.all {
      #expect(
        Set(integration.allEvents) == expected[integration.id],
        "\(integration.displayName)'s event set changed")
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
