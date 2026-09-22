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
    let result = HookConfiguration.install(into: [:], scriptPath: script)
    for event in HookConfiguration.claudeCodeEvents {
      #expect(commands(result, event: event).contains("\(script) \(event)"))
    }
  }

  @Test("leaves unrelated settings untouched")
  func preservesUnrelatedKeys() {
    let result = HookConfiguration.install(into: existingSettings(), scriptPath: script)
    #expect(result["theme"] as? String == "dark")
    #expect((result["someOtherSetting"] as? [String: Any])?["nested"] as? Bool == true)
  }

  @Test("leaves another tool's hooks in place")
  func preservesForeignHooks() {
    let result = HookConfiguration.install(into: existingSettings(), scriptPath: script)
    let pre = commands(result, event: "PreToolUse")
    #expect(pre.contains("\(other) PreToolUse"))
    #expect(pre.contains("\(script) PreToolUse"))
  }

  @Test("installing twice does not duplicate anything")
  func installIsIdempotent() {
    let once = HookConfiguration.install(into: existingSettings(), scriptPath: script)
    let twice = HookConfiguration.install(into: once, scriptPath: script)
    for event in HookConfiguration.claudeCodeEvents {
      let ours = commands(twice, event: event).filter { $0.hasPrefix(script) }
      #expect(ours.count == 1, "duplicated hook for \(event)")
    }
  }

  @Test("a moved app replaces its old hook rather than adding beside it")
  func replacesStalePath() {
    let old = "/Applications/Vigil.app/hooks/vigil-hook.sh"
    let installed = HookConfiguration.install(into: [:], scriptPath: old)
    let moved = HookConfiguration.install(into: installed, scriptPath: script)

    let pre = commands(moved, event: "PreToolUse")
    #expect(pre.contains { $0.hasPrefix(script) })
    #expect(!pre.contains { $0.hasPrefix(old) })
  }

  @Test("uninstall removes ours and keeps theirs")
  func uninstallIsSurgical() {
    let installed = HookConfiguration.install(into: existingSettings(), scriptPath: script)
    let removed = HookConfiguration.uninstall(from: installed, scriptPath: script)

    let pre = commands(removed, event: "PreToolUse")
    #expect(pre == ["\(other) PreToolUse"])
    #expect(removed["theme"] as? String == "dark")
  }

  @Test("uninstall leaves no empty scaffolding behind")
  func uninstallPrunes() {
    let installed = HookConfiguration.install(into: ["theme": "dark"], scriptPath: script)
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
    #expect(!HookConfiguration.isInstalled(in: [:], scriptPath: script))
    #expect(!HookConfiguration.isInstalled(in: existingSettings(), scriptPath: script))

    let installed = HookConfiguration.install(into: existingSettings(), scriptPath: script)
    #expect(HookConfiguration.isInstalled(in: installed, scriptPath: script))

    let removed = HookConfiguration.uninstall(from: installed, scriptPath: script)
    #expect(!HookConfiguration.isInstalled(in: removed, scriptPath: script))
  }

  @Test("a partial install is not reported as installed")
  func partialInstallIsNotInstalled() {
    let partial = HookConfiguration.install(
      into: [:], scriptPath: script, events: ["PreToolUse"])
    #expect(!HookConfiguration.isInstalled(in: partial, scriptPath: script))
  }
}
