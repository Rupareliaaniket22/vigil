import Foundation

@testable import Vigil

/// A home directory that is not the user's.
///
/// `HookInstaller` derives all four agents' settings paths and the shared
/// script path from `FileManager.homeDirectoryForCurrentUser`, and
/// `uninstall()` decides whether to delete a file from what it finds in all
/// four. Those paths are static, so there is no injection point: the only way
/// to exercise the delete rule is to move home out from under it. Anything
/// less runs the test against the developer's real `~/.claude`, `~/.codex`,
/// `~/.gemini` and `~/.cursor`, which is not a test, it is an incident.
///
/// `CFFIXED_USER_HOME` moves it. CoreFoundation reads that variable on every
/// call rather than caching it at launch, so setting it from inside the test
/// process works — which matters more than it sounds. The alternative was to
/// have the Makefile export it, and then a bare `swift test` would have run
/// these scenarios against the real home. Nothing here depends on how the
/// suite was started.
///
/// Two guards, because the failure being guarded against is silent and
/// destructive:
///
/// - The body does not run unless *both* `homeDirectoryForCurrentUser` and
///   `HookInstaller.defaultScriptPath` have actually moved inside the
///   temporary directory. A redirect that did not take throws; it never falls
///   back to the real home.
/// - The variable is process-global, so the body holds a lock and the previous
///   value is put back afterwards. Nothing else in this package reads home
///   and the suites using this are `.serialized`, but neither of those is a
///   property a future test is obliged to preserve, and the lock is.
enum FakeHome {

  /// The redirect did not take. Thrown rather than asserted so that the test
  /// fails having written nothing anywhere.
  struct NotRedirected: Error, CustomStringConvertible {
    let description: String
  }

  private static let lock = NSLock()

  /// Runs `body` with home pointed at a directory made for this call, and
  /// takes the directory away again afterwards.
  static func run<T>(_ body: (URL) throws -> T) throws -> T {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("vigil-fake-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    lock.lock()
    let previous = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]
    setenv("CFFIXED_USER_HOME", root.path, 1)
    defer {
      if let previous {
        setenv("CFFIXED_USER_HOME", previous, 1)
      } else {
        unsetenv("CFFIXED_USER_HOME")
      }
      lock.unlock()
      clear(root)
    }

    // Compared symlink-resolved on both sides: the temporary directory is
    // reached through /var/folders, which is a link into /private.
    let wanted = root.resolvingSymlinksInPath().path
    let got = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    guard got == wanted else {
      throw NotRedirected(
        description: "home did not move: wanted \(wanted), got \(got)")
    }
    // The end the test actually cares about. Home moving is the mechanism;
    // this is the thing being relied on.
    guard HookInstaller.defaultScriptPath.hasPrefix(root.path + "/") else {
      throw NotRedirected(
        description: "the installer's script path is outside the fake home: "
          + HookInstaller.defaultScriptPath)
    }

    return try body(root)
  }

  /// Delete the directory, including the parts a scenario made unreadable.
  ///
  /// Scenarios set files and directories to mode 000 on purpose — that is the
  /// defect being tested. `removeItem` cannot descend into a directory it
  /// cannot search, so walk it top-down putting the modes back first. We own
  /// every one of them, so the chmod always succeeds; skipping this would leak
  /// an undeletable directory per run.
  private static func clear(_ root: URL) {
    let fm = FileManager.default
    var directories = [root]
    while let directory = directories.popLast() {
      try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
      let children =
        (try? fm.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
      for child in children {
        if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
          directories.append(child)
        } else {
          try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: child.path)
        }
      }
    }
    try? fm.removeItem(at: root)
  }
}
