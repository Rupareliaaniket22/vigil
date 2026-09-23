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
      scriptName: "vigil-hook",
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
