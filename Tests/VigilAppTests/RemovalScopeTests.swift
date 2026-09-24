import Foundation
import Testing
import VigilCore

@testable import Vigil

/// What "Remove Vigil from This Mac…" decides is worth removing.
///
/// The loop behind that menu item asks each agent whether it holds anything
/// before touching its settings file, and the question has to be right in both
/// directions. Ask it too narrowly and the removal skips a file full of Vigil's
/// entries — which is the residue the whole feature exists to collect. Ask it
/// not at all and every removal rewrites and backs up four config files Vigil
/// has never touched, because Vigil reformats what it writes.
///
/// The first version derived the answer from `missingEvents`, which reports
/// everything missing whenever the shared script is absent or not executable.
/// A user whose `~/.vigil` had been deleted — hooks still wired into all four
/// agents, pointing at a script that is gone — read as four agents with nothing
/// in them. That case is the first test here.
@Suite("Deciding what a full removal has to remove")
struct RemovalScopeTests {

  @Test("an agent wired up by Vigil has something to remove")
  func installedAgentHasSomething() throws {
    try FakeHome.run { home in
      try writeScript(at: home.scriptPath)
      try writeInstalled(.claudeCode, in: home)

      #expect(home.installer(for: .claudeCode).hasSomethingToRemove)
    }
  }

  /// The case the first version got wrong. The entries are what has to come
  /// out of the user's file; whether the script they name still exists has
  /// nothing to do with it.
  @Test("entries still count when the shared script has been deleted")
  func entriesCountWithoutTheScript() throws {
    try FakeHome.run { home in
      try writeInstalled(.claudeCode, in: home)
      // No script written at all: `missingEvents` answers "all of them", which
      // is indistinguishable from an agent that was never set up.
      #expect(!FileManager.default.fileExists(atPath: home.scriptPath))
      #expect(
        home.installer(for: .claudeCode).missingEvents == AgentIntegration.claudeCode.allEvents)

      #expect(home.installer(for: .claudeCode).hasSomethingToRemove)
    }
  }

  @Test("an agent Vigil never touched has nothing to remove")
  func untouchedAgentHasNothing() throws {
    try FakeHome.run { home in
      try write(#"{"theme":"dark"}"#, to: home.settingsPath(for: .claudeCode))

      #expect(!home.installer(for: .claudeCode).hasSomethingToRemove)
    }
  }

  /// Someone else's hook in the same file is not ours, and a removal that
  /// counted it would rewrite — and back up — a file holding only their work.
  @Test("another tool's hook is not something to remove")
  func anotherToolsHookIsNotOurs() throws {
    try FakeHome.run { home in
      try write(
        #"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/opt/other/hook.sh"}]}]}}"#,
        to: home.settingsPath(for: .claudeCode))

      #expect(!home.installer(for: .claudeCode).hasSomethingToRemove)
    }
  }

  @Test("an agent with no settings file at all has nothing to remove")
  func absentSettingsFileHasNothing() throws {
    try FakeHome.run { home in
      #expect(!home.installer(for: .claudeCode).hasSomethingToRemove)
    }
  }

  /// One doubt is enough, the same way it is for the shared script's delete
  /// rule. A file that will not parse may hold our entries, and nothing here
  /// can look inside it — so it is handed to `uninstall()`, which refuses it
  /// by name in front of the user rather than passing over it in silence.
  @Test("a settings file that will not parse is not written off")
  func unreadableSettingsCountAsSomething() throws {
    try FakeHome.run { home in
      try write("{\"hooks\": ", to: home.settingsPath(for: .claudeCode))

      #expect(home.installer(for: .claudeCode).hasSomethingToRemove)
    }
  }

  // MARK: - Harness

  /// A settings file wired to the shared script, written by the same code that
  /// writes the real one.
  private func writeInstalled(_ integration: AgentIntegration, in home: FakeHome) throws {
    let settings = HookConfiguration.install(
      into: [:], scriptPath: home.scriptPath, integration: integration)
    try write(
      try JSONSerialization.data(
        withJSONObject: settings,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      to: home.settingsPath(for: integration))
  }

  private func writeScript(at path: String) throws {
    try write(Data("#!/bin/bash\nexit 0\n".utf8), to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  }

  private func write(_ text: String, to path: String) throws {
    try write(Data(text.utf8), to: path)
  }

  private func write(_ data: Data, to path: String) throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path))
  }
}
