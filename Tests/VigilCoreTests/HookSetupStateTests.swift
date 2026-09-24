import Foundation
import Testing

@testable import VigilCore

private let script = "/Users/x/.vigil/hooks/vigil-hook.sh"

@Suite("Recognising a half-installed agent")
struct HookSetupStateTests {

  /// The case that used to be invisible. Vigil's expected event set grew
  /// between versions, so an older install failed `isInstalled` — correctly —
  /// but the agent had live sessions, so it never reached the "needs setting
  /// up" list either. Nothing told the user, and the panel silently reported
  /// less than the truth.
  @Test("some of our hooks present and some absent reads as out of date")
  func partiallyInstalled() {
    #expect(
      HookConfiguration.setupState(missingEvents: ["Stop"], expectedEvents: ["PreToolUse", "Stop"])
        == .outOfDate)
  }

  @Test("an agent that has never been wired up reads as not set up")
  func nothingInstalled() {
    #expect(
      HookConfiguration.setupState(
        missingEvents: ["PreToolUse", "Stop"], expectedEvents: ["PreToolUse", "Stop"]
      ) == .notSetUp)
  }

  @Test("an agent with every hook we want is ready")
  func fullyInstalled() {
    #expect(
      HookConfiguration.setupState(missingEvents: [], expectedEvents: ["PreToolUse"]) == .ready)
  }

  /// Uninstalling removes every one of our hooks, so the agent lands on
  /// `notSetUp`. It must not keep an out-of-date badge and a button pressing
  /// the user to reinstall what they just deliberately removed.
  @Test("an uninstalled agent reads as not set up, not as out of date")
  func uninstalledIsNotOutOfDate() {
    let installed = HookConfiguration.install(
      into: [:], scriptPath: script, integration: .claudeCode)
    let removed = HookConfiguration.uninstall(from: installed, scriptPath: script)
    let missing = HookConfiguration.missingEvents(
      in: removed, scriptPath: script, integration: .claudeCode)
    #expect(
      HookConfiguration.setupState(
        missingEvents: missing, expectedEvents: AgentIntegration.claudeCode.allEvents
      ) == .notSetUp)
  }

  /// Simulates the upgrade exactly: install with yesterday's shorter event set,
  /// then ask today's integration what is missing.
  @Test("a settings file written by an older version names what it is missing")
  func missingEventsAfterAnUpgrade() {
    let old = AgentIntegration(
      id: .claudeCode,
      displayName: "Claude Code",
      settingsPath: ".claude/settings.json",
      workingEvents: ["UserPromptSubmit", "PreToolUse", "PostToolUse"],
      idleEvents: ["SessionEnd"]
    )
    let settings = HookConfiguration.install(into: [:], scriptPath: script, integration: old)

    let missing = HookConfiguration.missingEvents(
      in: settings, scriptPath: script, integration: .claudeCode)

    #expect(!missing.isEmpty)
    #expect(missing.contains("Stop"), "the event that ends a turn is the one that matters")
    #expect(!missing.contains("PreToolUse"), "an event the old install did register")
    #expect(
      !HookConfiguration.isInstalled(
        in: settings, scriptPath: script, integration: .claudeCode))
    #expect(
      HookConfiguration.setupState(
        missingEvents: missing, expectedEvents: AgentIntegration.claudeCode.allEvents
      ) == .outOfDate)
  }

  @Test("a current install is missing nothing", arguments: AgentIntegration.all)
  func nothingMissingWhenCurrent(integration: AgentIntegration) {
    let settings = HookConfiguration.install(
      into: [:], scriptPath: script, integration: integration)
    #expect(
      HookConfiguration.missingEvents(
        in: settings, scriptPath: script, integration: integration
      ).isEmpty)
    #expect(
      HookConfiguration.retiredEvents(
        in: settings, scriptPath: script, integration: integration
      ).isEmpty)
    #expect(
      HookConfiguration.setupState(
        missingEvents: [], expectedEvents: integration.allEvents, retiredEvents: []) == .ready)
  }

  /// The upgrade the other direction, and the one `missingEvents` cannot see.
  /// An older Vigil registered events this one has retired; every event we
  /// still want is present, so the install looks perfect — and the retired
  /// hooks go on firing. For Cursor that meant a hook that blocks the agent
  /// staying armed with nothing ever prompting the user to re-run setup.
  @Test("an install carrying hooks we have since retired is out of date")
  func retiredHooksReadAsOutOfDate() {
    let current = AgentIntegration.cursor
    let older = AgentIntegration(
      id: .cursor,
      displayName: "Cursor",
      settingsPath: ".cursor/hooks.json",
      workingEvents: current.workingEvents + ["beforeShellExecution"],
      idleEvents: current.idleEvents,
      entryFormat: .flat
    )
    let settings = HookConfiguration.install(into: [:], scriptPath: script, integration: older)

    let missing = HookConfiguration.missingEvents(
      in: settings, scriptPath: script, integration: current)
    let retired = HookConfiguration.retiredEvents(
      in: settings, scriptPath: script, integration: current)

    #expect(missing.isEmpty, "the older install did register everything we still want")
    #expect(retired == ["beforeShellExecution"])
    #expect(
      HookConfiguration.setupState(
        missingEvents: missing, expectedEvents: current.allEvents, retiredEvents: retired
      ) == .outOfDate,
      "an install with a retired hook still in it must not read as ready")
  }

  /// And the flip side: a genuinely untouched file must not be dragged into
  /// `outOfDate` by this, because nothing of ours is in it to be stale.
  @Test("retired events are only ever our own hooks", arguments: AgentIntegration.all)
  func retiredIgnoresOtherToolsHooks(integration: AgentIntegration) {
    let theirs: [String: Any] = [
      "hooks": ["SomeEventWeNeverWanted": [["command": "/opt/theirs/hook.sh"]]]
    ]
    #expect(
      HookConfiguration.retiredEvents(
        in: theirs, scriptPath: script, integration: integration
      ).isEmpty)
  }

  /// Which of the two the user is asked to do when both are true.
  ///
  /// Codex hashes the entry, so an entry of ours that changed since it was
  /// approved is out of date *and* `modified`, and the first caused the
  /// second. Sending that user to `/hooks` would have them approve the entry
  /// Vigil is about to replace — re-arming the hook the update exists to fix —
  /// and leave the file just as out of date afterwards.
  @Test("an install that is both stale and untrusted asks to be updated first")
  func outOfDateOutranksUntrusted() {
    #expect(
      HookConfiguration.setupState(
        missingEvents: [], expectedEvents: ["SessionStart"],
        outdatedEvents: ["SessionStart"],
        trust: .modified(events: ["SessionStart"])) == .outOfDate)
    #expect(
      HookConfiguration.setupState(
        missingEvents: [], expectedEvents: ["Stop"],
        retiredEvents: ["OldEvent"],
        trust: .untrusted(events: ["Stop"])) == .outOfDate)
  }

  /// And the case that made `untrusted` its own state in the first place is
  /// untouched: nothing of ours has drifted, so "Update" would be the no-op
  /// the old ordering existed to prevent.
  @Test("a current install the host will not run is still untrusted")
  func untrustedSurvivesTheReorder() {
    #expect(
      HookConfiguration.setupState(
        missingEvents: [], expectedEvents: ["Stop"],
        trust: .untrusted(events: ["Stop"])) == .untrusted)
    #expect(
      HookConfiguration.setupState(
        missingEvents: [], expectedEvents: ["Stop"],
        trust: .modified(events: ["Stop"])) == .untrusted)
  }

  /// A host too old for hooks at all still comes first. Neither re-installing
  /// nor approving anything can make that copy run a hook.
  @Test("nothing outranks a host that cannot run hooks")
  func hostTooOldStaysFirst() {
    #expect(
      HookConfiguration.setupState(
        missingEvents: [], expectedEvents: ["BeforeAgent"],
        outdatedEvents: ["BeforeAgent"],
        trust: .untrusted(events: ["BeforeAgent"]),
        host: HostHookSupport.verdict(
          copies: [HostCopy(path: "/usr/local/bin/gemini", version: HostVersion("0.1.22"))],
          floor: HookFloor(executable: "gemini", since: HostVersion(0, 19, 0))))
        == .hostTooOld)
  }

  @Test("an untouched settings file is missing every event", arguments: AgentIntegration.all)
  func everythingMissingWhenAbsent(integration: AgentIntegration) {
    let missing = HookConfiguration.missingEvents(
      in: ["theme": "dark"], scriptPath: script, integration: integration)
    #expect(Set(missing) == Set(integration.allEvents))
  }
}

@Suite("Settings files Vigil must not rewrite")
struct SettingsFileTests {

  @Test(
    "a settings file with comments is recognised",
    arguments: [
      "{\n  // where our hooks go\n  \"hooks\": {}\n}",
      "{\n  /* block */ \"hooks\": {}\n}",
      "{}// trailing",
    ])
  func detectsComments(text: String) {
    #expect(SettingsFile.containsComments(text))
  }

  /// The false positive that would matter: a URL in a string value contains
  /// `//`, and refusing on that would lock someone out of a file Vigil could
  /// have edited perfectly well.
  @Test(
    "a slash inside a string is not a comment",
    arguments: [
      #"{"url":"https://example.com/x"}"#,
      #"{"a":"/* not a comment */"}"#,
      #"{"a":"he said \"//\""}"#,
      #"{"path":"C:\\dir//sub"}"#,
      #"{"hooks":{"PreToolUse":[]}}"#,
    ])
  func doesNotFlagStrings(text: String) {
    #expect(!SettingsFile.containsComments(text))
  }

  @Test("an empty file is not a commented one")
  func emptyIsClean() {
    #expect(!SettingsFile.containsComments(""))
    #expect(!SettingsFile.containsComments("/"))
  }
}
