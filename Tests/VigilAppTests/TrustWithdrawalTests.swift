import Foundation
import Testing
import VigilCore

@testable import Vigil

/// Removing Vigil's hooks removes the approval that made them run.
///
/// `CodexTrustRemovalTests` pins the string surgery. This is the other half:
/// that the installer calls it, in the right order, against real files — and
/// that what the user sees afterwards is an agent Codex would not silently run
/// Vigil's hooks for if they came back.
///
/// The order is the part worth a test of its own. A trust record is derived
/// from the hook entries in `hooks.json`, so it can only be worked out while
/// they are still there. An uninstall that removed the entries first and then
/// asked what to withdraw would be handed an empty list every time and report
/// success, which is very close to the defect being fixed. `theRecordsMustBeRead
/// BeforeTheEntriesGo` is that claim, stated as a fact about the installer
/// rather than as a comment on the caller.
///
/// Runs against a `FakeHome`, which refuses to start the body unless every path
/// the installer can reach — including `config.toml`, which is the file being
/// written here — lands inside a temporary directory.
@Suite("Withdrawing Codex's trust when the hooks come out")
struct TrustWithdrawalTests {

  @Test("an uninstall takes the trust record out of config.toml")
  func uninstallWithdrawsTheRecord() throws {
    try FakeHome.run { home in
      let installer = try approvedCodex(in: home)
      #expect(installer.trustState == .trusted, "the fixture has to start trusted")

      let recorded = installer.selfWrittenTrustRecords()
      try installer.uninstall()
      #expect(try installer.removeTrust(recorded))

      let toml = try String(contentsOfFile: installer.codexConfigFilePath, encoding: .utf8)
      #expect(!toml.contains("hooks.state"), "left behind: \(toml)")
    }
  }

  /// The whole reason the record has to go. Vigil installs without asking, so
  /// a record left behind is a pre-approval waiting for the next launch — which
  /// is what was verified happening on a real machine: hooks installed, no
  /// trust write, and the state straight back to `trusted`.
  @Test("hooks installed again after a removal are not already approved")
  func aLaterInstallIsNotPreApproved() throws {
    try FakeHome.run { home in
      let installer = try approvedCodex(in: home)
      let recorded = installer.selfWrittenTrustRecords()
      try installer.uninstall()
      try installer.removeTrust(recorded)

      // Exactly what a later launch does, byte for byte — the same calls that
      // put the script and the entries there the first time. The script has to
      // come back too: the uninstall deleted it, because in this home nothing
      // else pointed at it.
      try writeScript(at: home.scriptPath)
      try writeInstalled(.codex, in: home)
      #expect(installer.isInstalled, "the second install has to land or this proves nothing")
      #expect(installer.trustState != .trusted)
    }
  }

  /// Stated against the installer because that is where it can be got wrong
  /// without anybody noticing: the list is empty after the entries go, so a
  /// caller that asked in the wrong order would withdraw nothing and say it
  /// had succeeded.
  @Test("there is nothing left to withdraw once the entries are gone")
  func theRecordsMustBeReadBeforeTheEntriesGo() throws {
    try FakeHome.run { home in
      let installer = try approvedCodex(in: home)
      #expect(!installer.selfWrittenTrustRecords().isEmpty)

      try installer.uninstall()
      #expect(installer.selfWrittenTrustRecords().isEmpty)
    }
  }

  /// A record under one of our keys that Vigil did not write is somebody
  /// else's, and `removeTrust` says so by answering false — which is what stops
  /// the settings row dropping a disclosure for an approval still in the file.
  @Test("a record Vigil did not write is left, and reported as left")
  func leavesARecordItDidNotWrite() throws {
    try FakeHome.run { home in
      let installer = try approvedCodex(in: home)
      let recorded = installer.selfWrittenTrustRecords()
      let mine = try #require(recorded.first)

      // The same key, a hash from somewhere else.
      let theirs = CodexTrustWriter.Record(
        key: mine.key, hash: "sha256:somebodyelseswork", event: mine.event)
      try write(
        "[hooks.state.\"\(theirs.key)\"]\ntrusted_hash = \"\(theirs.hash)\"\n",
        to: installer.codexConfigFilePath)

      try installer.uninstall()
      #expect(try installer.removeTrust(recorded) == false)

      let toml = try String(contentsOfFile: installer.codexConfigFilePath, encoding: .utf8)
      #expect(toml.contains(theirs.hash), "theirs is theirs")
    }
  }

  /// Three of the four hosts have no trust gate and no `config.toml`. Removing
  /// their hooks must not conjure one.
  @Test("a host with no trust gate writes no config.toml")
  func aHostWithoutAGateWritesNothing() throws {
    try FakeHome.run { home in
      try writeScript(at: home.scriptPath)
      try writeInstalled(.claudeCode, in: home)

      let installer = home.installer(for: .claudeCode)
      let recorded = installer.selfWrittenTrustRecords()
      #expect(recorded.isEmpty)
      try installer.uninstall()
      #expect(try installer.removeTrust(recorded) == false)

      #expect(!FileManager.default.fileExists(atPath: installer.codexConfigFilePath))
    }
  }

  // MARK: - Harness

  /// A Codex wired up the way a real install leaves it, with the approval Vigil
  /// would have written for it already in `config.toml`.
  ///
  /// Built by the same code that does it for real — `HookConfiguration.install`
  /// for the entries, `selfWrittenTrustRecords` for what may be approved, and
  /// `recordTrust` to write it — so a fixture cannot drift into a shape the app
  /// never produces.
  private func approvedCodex(in home: FakeHome) throws -> HookInstaller {
    try writeScript(at: home.scriptPath)
    try writeInstalled(.codex, in: home)

    let installer = home.installer(for: .codex)
    let records = installer.selfWrittenTrustRecords()
    #expect(!records.isEmpty, "nothing to approve means the fixture is wrong")
    try installer.recordTrust(records)
    return installer
  }

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
