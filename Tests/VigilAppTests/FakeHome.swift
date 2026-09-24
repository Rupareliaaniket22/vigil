import Foundation
import VigilCore

@testable import Vigil

/// A home directory that is not the user's.
///
/// `HookInstaller` resolves all four agents' settings paths, the shared script
/// and Codex's `config.toml` against a home directory, and `uninstall()`
/// decides whether to delete a file three other agents may be using from what
/// it finds in all four. Running that against the developer's real `~/.claude`,
/// `~/.codex`, `~/.gemini` and `~/.cursor` is not a test, it is an incident.
///
/// The home is a parameter now, so this is a directory and the paths taken
/// from it. There is no `CFFIXED_USER_HOME` to set, nothing process-global to
/// put back, no lock around the body, and nothing obliging two suites that use
/// this to run one at a time.
///
/// Injection does not make the old guard unnecessary, and this keeps it — what
/// changes is what the guard can ask. It used to ask whether an environment
/// variable had taken effect, which is the mechanism rather than the thing
/// being relied on. It now asks the installer itself, for every path it can
/// reach, where that path lands, and refuses to run the body unless all of
/// them are inside this directory. An installer that went back to reading
/// `homeDirectoryForCurrentUser` for any one of them fails that question
/// having written nothing — which the old check could not see at all, because
/// with the variable set a stray read of the real home was redirected too and
/// looked exactly like a pass.
///
/// The other half is that there is no call left to get wrong: a test takes its
/// installer from `installer(for:)` and its paths from `scriptPath` and
/// `settingsPath(for:)`, so the home is never something a test has to remember
/// to pass.
struct FakeHome {

  /// Something derived from this home landed outside it. Thrown rather than
  /// asserted so that the test fails having written nothing anywhere.
  struct NotRedirected: Error, CustomStringConvertible {
    let description: String
  }

  /// The directory itself. One per call, so two tests can never meet in it.
  let url: URL

  /// Runs `body` against a home made for this call, and takes it away again.
  static func run<T>(_ body: (FakeHome) throws -> T) throws -> T {
    let home = FakeHome(
      url: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vigil-fake-home-\(UUID().uuidString)", isDirectory: true))
    try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
    defer { home.clear() }

    try home.checkNothingEscapes()
    return try body(home)
  }

  /// Where the one script every agent shares goes, under this home.
  var scriptPath: String { HookInstaller.defaultScriptPath(home: url) }

  /// Where `integration` keeps its settings, under this home.
  func settingsPath(for integration: AgentIntegration) -> String {
    HookInstaller.settingsPath(for: integration, home: url)
  }

  /// An installer wired to this home in all three places it matters: the
  /// script an uninstall would delete, the settings file it would rewrite, and
  /// the home it reads the other three agents out of before deciding.
  func installer(for integration: AgentIntegration) -> HookInstaller {
    HookInstaller(
      scriptPath: scriptPath,
      settingsPath: settingsPath(for: integration),
      integration: integration,
      home: url
    )
  }

  /// Every path an installer built here can read or write, checked to be
  /// inside this directory before any test body runs.
  ///
  /// Asked of the real API rather than rebuilt from string literals. A copy of
  /// the path-building would agree with itself forever, including on the day
  /// the installer stopped honouring the home it is handed — which is the one
  /// day this is here for.
  private func checkNothingEscapes() throws {
    var paths = [scriptPath]
    for integration in AgentIntegration.all {
      let candidate = installer(for: integration)
      guard candidate.home == url else {
        throw NotRedirected(
          description: "\(integration.displayName)'s installer has home "
            + "\(candidate.home.path), not \(url.path)")
      }
      paths += [
        settingsPath(for: integration),
        candidate.scriptPath,
        candidate.settingsPath,
        candidate.codexConfigFilePath,
      ]
    }

    // Compared as written rather than symlink-resolved: every one of these is
    // this URL with components appended, so they share its spelling exactly,
    // and most of them name a file that does not exist yet — which is not
    // something `resolvingSymlinksInPath` promises anything about.
    let inside = url.path + "/"
    for path in paths where !path.hasPrefix(inside) {
      throw NotRedirected(description: "\(path) is outside the fake home \(url.path)")
    }
  }

  /// Delete the directory, including the parts a scenario made unreadable.
  ///
  /// Scenarios set files and directories to mode 000 on purpose — that is the
  /// defect being tested. `removeItem` cannot descend into a directory it
  /// cannot search, so walk it top-down putting the modes back first. We own
  /// every one of them, so the chmod always succeeds; skipping this would leak
  /// an undeletable directory per run.
  private func clear() {
    let fm = FileManager.default
    var directories = [url]
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
    try? fm.removeItem(at: url)
  }
}
