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

private func commands(_ settings: [String: Any], event: String) -> [String] {
  guard let hooks = settings["hooks"] as? [String: Any],
    let matchers = hooks[event] as? [[String: Any]]
  else { return [] }
  return matchers.flatMap { matcher in
    (matcher["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
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
          .contains("\(script) claude-code \(event) \(state.rawValue)"))
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
    #expect(pre.contains { $0.hasPrefix(script) })
  }

  @Test("installing twice does not duplicate anything")
  func installIsIdempotent() {
    let once = HookConfiguration.install(
      into: existingSettings(), scriptPath: script, integration: .claudeCode)
    let twice = HookConfiguration.install(into: once, scriptPath: script, integration: .claudeCode)
    for event in AgentIntegration.claudeCode.allEvents {
      let ours = commands(twice, event: event).filter { $0.hasPrefix(script) }
      #expect(ours.count == 1, "duplicated hook for \(event)")
    }
  }

  @Test("a moved app replaces its old hook rather than adding beside it")
  func replacesStalePath() {
    let old = "/Applications/Vigil.app/hooks/vigil-hook.sh"
    let installed = HookConfiguration.install(into: [:], scriptPath: old, integration: .claudeCode)
    let moved = HookConfiguration.install(
      into: installed, scriptPath: script, integration: .claudeCode)

    let pre = commands(moved, event: "PreToolUse")
    #expect(pre.contains { $0.hasPrefix(script) })
    #expect(!pre.contains { $0.hasPrefix(old) })
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

  @Test("each agent's events map to the right state", arguments: AgentIntegration.all)
  func eventsMapCorrectly(integration: AgentIntegration) {
    for event in integration.workingEvents {
      #expect(integration.state(for: event) == .working, "\(event) should be working")
    }
    for event in integration.waitingEvents {
      #expect(integration.state(for: event) == .waiting, "\(event) should be waiting")
    }
    for event in integration.idleEvents {
      #expect(integration.state(for: event) == .idle, "\(event) should be idle")
    }
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
        "\(script) \(integration.id.rawValue) \(event) \(integration.state(for: event).rawValue)"
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
