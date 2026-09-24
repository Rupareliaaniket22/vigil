import Foundation
import Testing

@testable import Vigil

/// The one file every agent's hook entry points at, and whether it is ever the
/// one this build of Vigil would install.
///
/// It was not. `copyScript()` had a single caller, `install()`, and `install()`
/// runs only when an agent's *settings file* is short of Vigil's entries, holds
/// entries for retired events, or holds a command Vigil no longer writes —
/// three questions asked of the entries and none asked of the script. So a user
/// who replaced Vigil.app with a version whose entries happened to be identical
/// kept the old `~/.vigil/hooks/vigil-hook.sh` and went on running it: every fix
/// to the hook script after the release they installed reached nobody who had
/// already installed.
///
/// These tests drive `refreshSharedScript(at:from:)` against a fake home and a
/// stand-in bundle, because the two things it compares are a path and a file
/// and neither of them needs to be real to be wrong. Pointed at the version
/// before the fix there is nothing to point at — the function did not exist —
/// so what they guard is the behaviour not being quietly narrowed later: the
/// mode check, the "installed or not" rule, and the refusal to create anything.
@Suite("Keeping the shared hook script current")
struct SharedScriptRefreshTests {

  // MARK: - Bringing it up to date

  @Test("a script from an older version is replaced")
  func replacesAnOlderScript() throws {
    try FakeHome.run { home in
      let bundled = try bundledScript("#!/bin/sh\necho new\n", in: home)
      try install("#!/bin/sh\necho old\n", at: home.scriptPath)

      #expect(HookInstaller.refreshSharedScript(at: home.scriptPath, from: bundled) == .refreshed)
      #expect(try contents(of: home.scriptPath) == "#!/bin/sh\necho new\n")
    }
  }

  @Test("the replacement is executable")
  func replacementIsExecutable() throws {
    try FakeHome.run { home in
      let bundled = try bundledScript("#!/bin/sh\necho new\n", in: home)
      try install("#!/bin/sh\necho old\n", at: home.scriptPath)

      _ = HookInstaller.refreshSharedScript(at: home.scriptPath, from: bundled)
      #expect(FileManager.default.isExecutableFile(atPath: home.scriptPath))
      #expect(try mode(of: home.scriptPath) == 0o755)
    }
  }

  /// The case that made the mode part of the comparison rather than part of the
  /// write. A copy that matches the bundle byte for byte but has lost its
  /// executable bit fires nothing at all, and every agent holding an entry that
  /// points at it reads to `missingEvents` as an agent that was never set up.
  @Test("a copy that matches but cannot be executed gets its mode back")
  func restoresTheExecutableBit() throws {
    try FakeHome.run { home in
      let script = "#!/bin/sh\necho same\n"
      let bundled = try bundledScript(script, in: home)
      try install(script, at: home.scriptPath)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: home.scriptPath)

      #expect(HookInstaller.refreshSharedScript(at: home.scriptPath, from: bundled) == .refreshed)
      #expect(FileManager.default.isExecutableFile(atPath: home.scriptPath))
    }
  }

  @Test("a copy that is already this build's is left alone")
  func leavesACurrentScriptAlone() throws {
    try FakeHome.run { home in
      let script = "#!/bin/sh\necho same\n"
      let bundled = try bundledScript(script, in: home)
      try install(script, at: home.scriptPath)
      let before = try modified(home.scriptPath)

      #expect(HookInstaller.refreshSharedScript(at: home.scriptPath, from: bundled) == .upToDate)
      // Not merely "the bytes are still right": an unconditional rewrite would
      // also leave the bytes right, on every panel open, forever.
      #expect(try modified(home.scriptPath) == before)
    }
  }

  // MARK: - What it must not do

  /// The whole of the consent argument for running this ahead of the "set up
  /// and update agent hooks automatically" switch. It writes into `~/.vigil`,
  /// which Vigil made, and only where Vigil has already been asked to put a
  /// script there. Somebody who has never let Vigil write anything must still
  /// have nothing written — not even the directory.
  @Test("nothing installed means nothing written, and no directory made")
  func writesNothingWhenNothingIsInstalled() throws {
    try FakeHome.run { home in
      let bundled = try bundledScript("#!/bin/sh\necho new\n", in: home)

      #expect(
        HookInstaller.refreshSharedScript(at: home.scriptPath, from: bundled) == .notInstalled)
      #expect(!FileManager.default.fileExists(atPath: home.scriptPath))
      let directory = (home.scriptPath as NSString).deletingLastPathComponent
      #expect(!FileManager.default.fileExists(atPath: directory))
    }
  }

  /// A bundle with no script in it cannot install either, and `install()` says
  /// so where somebody is waiting to hear it. Nothing presses this one, so it
  /// reports and leaves the working script exactly where it is — which is the
  /// only safe answer: the entries in four config files still name it.
  @Test("a bundle with no script in it changes nothing")
  func leavesTheScriptWhenTheBundleHasNone() throws {
    try FakeHome.run { home in
      try install("#!/bin/sh\necho old\n", at: home.scriptPath)

      guard case .failed = HookInstaller.refreshSharedScript(at: home.scriptPath, from: nil) else {
        Issue.record("a missing bundled script should be reported, not ignored")
        return
      }
      #expect(try contents(of: home.scriptPath) == "#!/bin/sh\necho old\n")
    }
  }

  /// `writeScript` stages the new bytes beside the destination so the rename
  /// cannot cross a filesystem. A stage that is not cleaned up leaves a dotfile
  /// in the directory `Scripts/uninstall.sh` expects to be able to `rmdir`.
  @Test("a refresh leaves nothing beside the script")
  func leavesNoStagingFile() throws {
    try FakeHome.run { home in
      let bundled = try bundledScript("#!/bin/sh\necho new\n", in: home)
      try install("#!/bin/sh\necho old\n", at: home.scriptPath)

      _ = HookInstaller.refreshSharedScript(at: home.scriptPath, from: bundled)

      let directory = URL(fileURLWithPath: home.scriptPath).deletingLastPathComponent()
      let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(left == ["vigil-hook.sh"])
    }
  }

  // MARK: - Helpers

  /// A stand-in for the copy inside the app bundle. Somewhere under the fake
  /// home, so `FakeHome` takes it away with everything else.
  private func bundledScript(_ body: String, in home: FakeHome) throws -> URL {
    let url = home.url.appendingPathComponent("bundle/vigil-hook.sh")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try body.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// An already-installed script, at the path four agents would be naming.
  private func install(_ body: String, at path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  }

  private func contents(of path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
  }

  private func mode(of path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
  }

  private func modified(_ path: String) throws -> Date {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.modificationDate] as? Date) ?? .distantPast
  }
}
