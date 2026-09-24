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

  @Test("installs a hook for every entry we register", arguments: AgentIntegration.all)
  func installsEveryRegistration(integration: AgentIntegration) {
    let result = HookConfiguration.install(
      into: [:], scriptPath: script, integration: integration)
    for registration in integration.registrations {
      let expected =
        "'\(script)' \(integration.id.rawValue) \(registration.event) "
        + registration.state.rawValue
      #expect(
        commands(result, event: registration.event).contains(expected),
        "\(integration.displayName) did not write \(expected)")
    }
  }

  /// The matcher is what makes two entries for one event two different things.
  /// Written without it they would be two copies of the same hook firing on
  /// every payload, which is worse than the single entry they replaced.
  @Test("an entry that narrows an event carries the host's matcher")
  func writesMatchers() {
    let result = HookConfiguration.install(into: [:], scriptPath: script, integration: .claudeCode)
    let groups = (result["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]] ?? []

    #expect(groups.count == 2, "Notification should be registered twice, once per meaning")
    let byState = Dictionary(
      uniqueKeysWithValues: groups.compactMap { group -> (String, String)? in
        guard let matcher = group["matcher"] as? String,
          let command = (group["hooks"] as? [[String: Any]])?.first?["command"] as? String,
          let state = command.split(separator: " ").last
        else { return nil }
        return (String(state), matcher)
      })

    #expect(byState["waiting"]?.contains("permission_prompt") == true)
    #expect(byState["idle"] == "idle_prompt")
    // Disjoint, or a single notification would fire two hooks disagreeing
    // about what it meant — and neither host deduplicates overlapping groups.
    let waiting = Set((byState["waiting"] ?? "").split(separator: "|"))
    let idle = Set((byState["idle"] ?? "").split(separator: "|"))
    #expect(waiting.isDisjoint(with: idle))
  }

  /// An unmatched entry must stay unmatched. `"matcher": ""` reads as
  /// match-all to both hosts, so it would behave the same — and for Codex it
  /// would change the hashed trust identity of every hook Vigil has installed,
  /// turning every approval the user has already given into `modified`.
  @Test("an entry with no matcher writes no matcher key", arguments: AgentIntegration.all)
  func unmatchedEntriesCarryNoMatcherKey(integration: AgentIntegration) {
    let result = HookConfiguration.install(
      into: [:], scriptPath: script, integration: integration)
    let hooks = result["hooks"] as? [String: Any] ?? [:]
    let matched = Set(integration.matchedEvents.map(\.event))
    for event in integration.allEvents where !matched.contains(event) {
      for group in hooks[event] as? [[String: Any]] ?? [] {
        #expect(group["matcher"] == nil, "\(integration.displayName) wrote a matcher on \(event)")
      }
    }
  }

  /// Cursor's entries have no group to hang a matcher on, and Cursor publishes
  /// no matcher metadata to hang there. A registration asking for one would be
  /// written into a flat entry that the host ignores, so the hook would fire
  /// for everything while the code claimed it was narrowed.
  @Test("no flat-format host registers a matcher")
  func flatHostsHaveNoMatchers() {
    for integration in AgentIntegration.all where integration.entryFormat == .flat {
      #expect(
        integration.matchedEvents.isEmpty,
        "\(integration.displayName) writes flat entries, which cannot carry a matcher")
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
      // One per registration, not one per event: an event registered twice
      // with two matchers is meant to hold two entries, and counting them as
      // duplicates would have hidden the real duplication underneath.
      let expected = integration.registrations.filter { $0.event == event }.count
      let ours = commands(twice, event: event).filter { $0.contains(script) }
      #expect(
        ours.count == expected,
        "\(integration.displayName) wrote \(ours.count) hooks for \(event), wanted \(expected)")
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

    // An event whose meaning lives in a payload field is deliberately absent
    // from all three arrays: it has no single state, and listing it in one
    // would both give `state(for:)` a wrong answer to hand out and make
    // `install` write an unmatched entry beside the matched ones — which is
    // the bug the matchers exist to remove, reintroduced as a duplicate.
    for registration in integration.matchedEvents {
      #expect(
        !integration.workingEvents.contains(registration.event)
          && !integration.waitingEvents.contains(registration.event)
          && !integration.idleEvents.contains(registration.event),
        "\(registration.event) is both matched and unconditionally registered")
      #expect(
        registration.matcher != nil,
        "\(registration.event) is listed as matched and carries no matcher")
    }

    let written = integration.registrations.map { "\($0.event)\u{1F}\($0.matcher ?? "")" }
    #expect(
      Set(written).count == written.count,
      "\(integration.displayName) writes the same entry twice, so one event fires two hooks")
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
        "SessionEnd", "SessionStart",
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
    // Claude Code: `PermissionRequest` ("When a permission dialog is
    // displayed") and `Elicitation` ("When an MCP server requests user
    // input"). `Notification` used to be a third, unconditionally, and is now
    // a matched entry — see `notificationIsSplitByType`.
    #expect(
      Set(AgentIntegration.claudeCode.waitingEvents) == ["PermissionRequest", "Elicitation"])
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

  /// Every entry Vigil writes, pinned — the golden master `allEvents` can no
  /// longer be.
  ///
  /// An event that appears once in `allEvents` may be two entries with two
  /// states, so the event set alone would no longer notice `idle_prompt`
  /// quietly becoming `waiting` again, or the `compact` source creeping back
  /// into Codex's matcher. Both of those are the *dangerous* direction: the
  /// first stops a run ever ending, the second drops the wake hold in the
  /// middle of the slowest request a Codex session makes.
  @Test("the matched entries only change on purpose")
  func matchedEntriesArePinned() {
    let expected: [AgentKind: [HookRegistration]] = [
      .claudeCode: [
        HookRegistration(
          event: "Notification", state: .waiting,
          matcher: "permission_prompt|agent_needs_input|worker_permission_prompt"
            + "|elicitation_dialog|elicitation_url_dialog"),
        HookRegistration(event: "Notification", state: .idle, matcher: "idle_prompt"),
      ],
      .codex: [
        HookRegistration(
          event: "SessionStart", state: .idle, matcher: "startup|resume|clear|fork")
      ],
      .gemini: [],
      .cursor: [],
    ]
    for integration in AgentIntegration.all {
      #expect(
        integration.matchedEvents == expected[integration.id],
        "\(integration.displayName)'s matched entries changed")
    }
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
  ///
  /// Registering the event at all was the first bug and un-registering it whole
  /// was the blunt fix. What has to hold is narrower and permanent: whatever
  /// Vigil registers for `SessionStart`, `compact` must not reach it.
  @Test("Codex's SessionStart never fires for a mid-turn compaction")
  func codexSessionStartExcludesCompact() {
    for registration in AgentIntegration.codex.registrations
    where registration.event == "SessionStart" {
      let sources = Set((registration.matcher ?? "").split(separator: "|").map(String.init))
      #expect(
        !sources.isEmpty,
        """
        Codex's SessionStart is registered with no matcher, so it fires on the \
        compact source mid-turn and drops the wake hold across the slowest \
        request in the session
        """)
      #expect(!sources.contains("compact"), "the compact source is a mid-turn event, not a start")
      // The other four are the real ones, and the matcher is compared as an
      // exact list — a name that is not one of Codex's five matches nothing
      // and quietly registers a hook that can never fire.
      #expect(sources.isSubset(of: ["startup", "resume", "clear", "fork"]))
    }
  }

  /// `Notification` means at least three different things depending on its
  /// `notification_type`, and Vigil used to read every one of them as
  /// `waiting`. The mid-turn values — `elicitation_complete`, `auth_success`,
  /// `computer_use_exit` and the rest — therefore dropped the wake hold while
  /// the agent was still working, which is the one failure this app exists to
  /// prevent.
  @Test("Claude Code's Notification is split by notification_type")
  func notificationIsSplitByType() {
    let ours = AgentIntegration.claudeCode.registrations.filter { $0.event == "Notification" }
    #expect(ours.count == 2)

    let values = Dictionary(
      uniqueKeysWithValues: ours.map {
        ($0.state, Set(($0.matcher ?? "").split(separator: "|").map(String.init)))
      })

    // Blocked on a human.
    #expect(values[.waiting]?.contains("permission_prompt") == true)
    #expect(values[.waiting]?.contains("agent_needs_input") == true)
    // The REPL sitting at the prompt with nothing running. Its notifier checks
    // that no dialog and no overlay is on screen before it fires, so this
    // cannot arrive while a permission prompt is up.
    #expect(values[.idle] == ["idle_prompt"])

    // And the mid-turn values are registered for by nobody. Not `working` —
    // that would hold the Mac awake for a session that had finished — but
    // nothing at all, so the session keeps the state its last real event gave
    // it. An eighteenth value Claude Code adds tomorrow gets the same.
    let registered = values.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    for midTurn in [
      "elicitation_complete", "elicitation_response", "auth_success", "agent_completed",
      "computer_use_enter", "computer_use_exit", "push_notification", "model_refusal_fallback",
      "quota_auto_resume_fired", "quota_auto_resume_stale", "quota_auto_resume_disabled",
    ] {
      #expect(!registered.contains(midTurn), "\(midTurn) arrives mid-turn and must fire nothing")
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

    let matched = Set(integration.matchedEvents.map(\.event))
    for event in integration.allEvents where !matched.contains(event) {
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

/// Upgrading an install written before an event could be registered twice.
///
/// Several entries under one event name is a shape this file had never written,
/// and every check that reads a settings file was phrased for one. The failure
/// to avoid is the quiet one: an old install that still satisfies every check,
/// so the user is never offered the button that would fix it — which is exactly
/// how the pre-quoting form survived a release.
@Suite("Upgrading to matched entries")
struct MatchedEntryUpgradeTests {

  /// Claude Code as Vigil wrote it before `Notification` was split: one entry
  /// per event, no matcher anywhere, and `waiting` baked into `Notification`
  /// for every `notification_type` there is.
  private static let beforeMatchers = AgentIntegration(
    id: .claudeCode,
    displayName: "Claude Code",
    settingsPath: ".claude/settings.json",
    workingEvents: [
      "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
    ],
    waitingEvents: ["Notification", "PermissionRequest", "Elicitation"],
    idleEvents: ["Stop", "StopFailure", "SessionEnd"]
  )

  private func oldInstall() -> [String: Any] {
    HookConfiguration.install(into: [:], scriptPath: script, integration: Self.beforeMatchers)
  }

  /// The event set did not change, so nothing about *which* events are present
  /// can notice this. Both of the checks that answer that question are happy.
  @Test("the event-level checks cannot see it")
  func eventChecksAreBlind() {
    let settings = oldInstall()
    #expect(
      HookConfiguration.missingEvents(
        in: settings, scriptPath: script, integration: .claudeCode
      ).isEmpty)
    #expect(
      HookConfiguration.retiredEvents(
        in: settings, scriptPath: script, integration: .claudeCode
      ).isEmpty)
  }

  /// So this has to, and it has to name the one event that changed rather than
  /// shrugging at the whole file.
  @Test("the entry-level check names Notification and nothing else")
  func outdatedNamesNotification() {
    #expect(
      HookConfiguration.outdatedEvents(
        in: oldInstall(), scriptPath: script, integration: .claudeCode) == ["Notification"])
  }

  @Test("and the agent reads as out of date, so Update is offered")
  func readsAsOutOfDate() {
    let settings = oldInstall()
    #expect(
      HookConfiguration.setupState(
        missingEvents: HookConfiguration.missingEvents(
          in: settings, scriptPath: script, integration: .claudeCode),
        expectedEvents: AgentIntegration.claudeCode.allEvents,
        retiredEvents: HookConfiguration.retiredEvents(
          in: settings, scriptPath: script, integration: .claudeCode),
        outdatedEvents: HookConfiguration.outdatedEvents(
          in: settings, scriptPath: script, integration: .claudeCode)
      ) == .outOfDate)
  }

  /// Pressing Update has to be the fix, which means the sweep must take the old
  /// unmatched entry out rather than leaving it beside the two new ones — it
  /// would go on firing `waiting` for every `notification_type` if it stayed.
  @Test("re-running the install replaces the one entry with the two")
  func installReplacesIt() {
    let updated = HookConfiguration.install(
      into: oldInstall(), scriptPath: script, integration: .claudeCode)
    let groups =
      (updated["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]] ?? []

    #expect(groups.count == 2)
    #expect(groups.allSatisfy { $0["matcher"] is String }, "the unmatched entry survived")
    #expect(
      HookConfiguration.outdatedEvents(
        in: updated, scriptPath: script, integration: .claudeCode
      ).isEmpty)
  }

  /// Half an upgrade is still an upgrade to finish: an event holding one of the
  /// two entries it should have is an event that reports the wrong thing for
  /// every payload the missing one covers.
  @Test("one of the two entries present is still out of date")
  func halfInstalledIsOutOfDate() {
    var settings = HookConfiguration.install(
      into: [:], scriptPath: script, integration: .claudeCode)
    var hooks = settings["hooks"] as! [String: Any]
    hooks["Notification"] = [(hooks["Notification"] as! [[String: Any]])[0]]
    settings["hooks"] = hooks

    #expect(
      HookConfiguration.missingEvents(
        in: settings, scriptPath: script, integration: .claudeCode
      ).isEmpty, "one of ours is there, so the event-level check is satisfied")
    #expect(
      HookConfiguration.outdatedEvents(
        in: settings, scriptPath: script, integration: .claudeCode) == ["Notification"])
  }

  /// Uninstalling has to take both, and leave no scaffolding behind.
  @Test("uninstall removes every entry under a doubly-registered event")
  func uninstallTakesBoth() {
    let installed = HookConfiguration.install(
      into: ["hooks": ["Notification": [["hooks": [["type": "command", "command": other]]]]]],
      scriptPath: script, integration: .claudeCode)
    #expect(commands(installed, event: "Notification").count == 3)

    let removed = HookConfiguration.uninstall(from: installed, scriptPath: script)
    #expect(commands(removed, event: "Notification") == [other])
  }

  /// The same command under a different matcher is a different entry. An
  /// install that somehow held both of our commands with no matchers on either
  /// would fire both for every `notification_type` — the original bug twice
  /// over — and the command alone cannot say so.
  @Test("the right commands under the wrong matchers are still out of date")
  func matchersAreCompared() {
    let ours = AgentIntegration.claudeCode.registrations.filter { $0.event == "Notification" }
    let settings: [String: Any] = [
      "hooks": [
        "Notification": ours.map { registration in
          [
            "hooks": [
              [
                "type": "command",
                "command": HookConfiguration.command(
                  scriptPath: script, integration: .claudeCode, registration: registration),
              ]
            ]
          ]
        }
      ]
    ]
    #expect(
      HookConfiguration.outdatedEvents(
        in: settings, scriptPath: script, integration: .claudeCode) == ["Notification"])
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
