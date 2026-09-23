import Foundation
import Testing
import VigilCore

@testable import Vigil

/// Uninstalling one agent must not delete the script the other three are using.
///
/// One `~/.vigil/hooks/vigil-hook.sh` serves Claude Code, Codex, Gemini CLI and
/// Cursor, so an uninstall may only remove it once nothing points at it. The
/// defect was in how "nothing points at it" was decided: the check read each of
/// the other three settings files with `try?`, so a file that would not read —
/// malformed JSON, a JSON comment, a root that is not an object, mode 000, a
/// parent directory that cannot be searched — voted "not referenced". Any one
/// of those deleted the script out from under three working agents, leaving
/// hook entries that still look correct pointing at a file that is not there.
/// Nothing fires, nothing says why, and the first anyone hears of it is a Mac
/// that slept mid-run.
///
/// These tests drive `uninstall()` and look at the file, rather than asserting
/// on the three-valued `ScriptReference` the fix introduced. That is
/// deliberate: stated this way the same file compiles and runs against the
/// version of `HookInstaller` that had the defect, which is the only way to
/// show it catches it. Pointed at `f353192~1`, all four "keeps the script"
/// cases fail and the three below them still pass — so the suite is catching
/// the defect rather than describing whatever the code happens to do.
///
/// Serialized because `FakeHome` moves a process-global environment variable.
@Suite("The hook script every agent shares", .serialized)
struct SharedHookScriptTests {

  // MARK: - Scenarios that must keep the script

  @Test("a sibling holding unparseable JSON keeps the script")
  func unparseableSiblings() throws {
    #expect(
      try uninstallClaudeCode {
        // Three different ways `readSettings` refuses, one per agent.
        try write("{\"hooks\": ", to: settingsPath(for: .codex))
        try write("{\n  // vigil\n  \"hooks\": {}\n}", to: settingsPath(for: .gemini))
        try write("[1, 2, 3]", to: settingsPath(for: .cursor))
      } == .kept)
  }

  /// Skipped as root, where the mode is not enforced and the scenario cannot
  /// arise. Better than a test that reports a defect that is not there.
  @Test("a sibling that cannot be opened keeps the script", .enabled(if: getuid() != 0))
  func unreadableSiblings() throws {
    #expect(
      try uninstallClaudeCode {
        for agent in siblings { try chmod(0o000, settingsPath(for: agent)) }
      } == .kept)
  }

  /// The case `fileExists` got wrong and `stat` gets right: a settings file
  /// whose directory cannot be searched is not an absent settings file.
  @Test(
    "a sibling in a directory that cannot be searched keeps the script",
    .enabled(if: getuid() != 0))
  func unsearchableSiblingDirectory() throws {
    #expect(
      try uninstallClaudeCode {
        for agent in siblings {
          try chmod(0o000, (settingsPath(for: agent) as NSString).deletingLastPathComponent)
        }
      } == .kept)
  }

  /// One doubt is enough. Two clean "no"s do not outvote it, because the
  /// reference that must not be broken would be hiding in the third.
  @Test(
    "one unreadable sibling outweighs two that plainly do not use it",
    .enabled(if: getuid() != 0))
  func oneUnreadableSiblingAmongAbsentOnes() throws {
    #expect(
      try uninstallClaudeCode {
        for agent in siblings { try remove(settingsPath(for: agent)) }
        try write("{\"hooks\": ", to: settingsPath(for: .codex))
      } == .kept)
  }

  @Test("a sibling that is still installed keeps the script")
  func installedSiblings() throws {
    #expect(try uninstallClaudeCode {} == .kept)
  }

  // MARK: - Scenarios that must delete it

  // Without these two the suite would pass against an installer that never
  // deleted anything, which is not the behaviour being asked for: an uninstall
  // that leaves its own script behind forever is a different bug.

  @Test("the last agent out deletes the script")
  func noSiblingUsesIt() throws {
    #expect(
      try uninstallClaudeCode {
        for agent in siblings { try write("{}", to: settingsPath(for: agent)) }
      } == .deleted)
  }

  @Test("siblings that were never installed delete the script")
  func noSiblingSettingsAtAll() throws {
    #expect(
      try uninstallClaudeCode {
        for agent in siblings { try remove(settingsPath(for: agent)) }
      } == .deleted)
  }

  // MARK: - Harness

  enum Outcome: Equatable {
    case kept
    case deleted
  }

  private let siblings: [AgentIntegration] = [.codex, .gemini, .cursor]

  /// Installs all four agents into a fake home, lets `disturb` do something to
  /// the other three, uninstalls Claude Code, and reports what became of the
  /// shared script.
  private func uninstallClaudeCode(
    disturb: () throws -> Void
  ) throws -> Outcome {
    try FakeHome.run { _ in
      let script = HookInstaller.defaultScriptPath
      try writeScript(at: script)
      for agent in AgentIntegration.all { try writeInstalled(agent, scriptPath: script) }

      try disturb()

      let installer = HookInstaller(
        scriptPath: script,
        settingsPath: settingsPath(for: .claudeCode),
        integration: .claudeCode
      )
      try installer.uninstall()

      // Proves the uninstall itself ran, so that "the script survived" can
      // never be read as "nothing happened at all".
      #expect(!installer.isInstalled)

      return FileManager.default.fileExists(atPath: script) ? .kept : .deleted
    }
  }

  /// Where an agent keeps its settings, under whichever home is in force.
  ///
  /// Spelled out rather than calling `HookInstaller.settingsPath(for:)`, which
  /// the fix added. Keeping this file free of anything the fix introduced is
  /// what lets it be pointed at the pre-fix installer.
  private func settingsPath(for integration: AgentIntegration) -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(integration.settingsPath).path
  }

  /// A settings file wired to the shared script, the way a real install leaves
  /// it — built by the same code that writes the real one.
  private func writeInstalled(_ integration: AgentIntegration, scriptPath: String) throws {
    let settings = HookConfiguration.install(
      into: [:], scriptPath: scriptPath, integration: integration)
    try write(
      try JSONSerialization.data(
        withJSONObject: settings,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      to: settingsPath(for: integration))
  }

  private func writeScript(at path: String) throws {
    try write(Data("#!/bin/bash\nexit 0\n".utf8), to: path)
    try chmod(0o755, path)
  }

  private func write(_ text: String, to path: String) throws {
    try write(Data(text.utf8), to: path)
  }

  private func write(_ data: Data, to path: String) throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path))
  }

  private func remove(_ path: String) throws {
    try? FileManager.default.removeItem(atPath: path)
  }

  private func chmod(_ mode: Int, _ path: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
  }
}
