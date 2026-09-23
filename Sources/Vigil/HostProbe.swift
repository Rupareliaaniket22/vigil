import Foundation
import OSLog
import VigilCore

/// Looks for the copies of a host's command that exist on this Mac, so
/// `HostHookSupport` can say whether any of them could run the hooks Vigil
/// installed.
///
/// Sits beside `HookInstaller` rather than in `VigilCore` for the usual reason:
/// it is all filesystem. The rule that turns what it finds into a verdict is
/// `HostHookSupport.verdict(copies:floor:)`, which is pure and tested — the
/// looking is here, the judging is there, and the judging is where a false
/// accusation would come from.
///
/// Cached, and that is the point of the type rather than an optimisation, the
/// same as `HelperDrift` beside it. `AppModel.refreshInstalledAgents` runs at
/// launch and on every panel open, and answering a question whose answer only
/// changes when somebody installs something is not work a power utility should
/// be doing four times per open.
@MainActor
enum HostProbe {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "host")

  // MARK: - The search path, and why it is written down

  /// Where Vigil looks for a host's command.
  ///
  /// **Not `PATH`.** This is the limitation the whole design is built around,
  /// and it is worth stating exactly. Vigil runs from a GUI bundle, so its
  /// environment is whatever launched it — and that is not one thing. A Vigil
  /// opened from Finder, or started by a login item, inherits launchd's
  /// `PATH`, which on a stock Mac is `/usr/bin:/bin:/usr/sbin:/sbin` and holds
  /// none of the places a coding agent is ever installed. A Vigil started from
  /// a terminal inherits that terminal's, which holds all of them. Reading
  /// `getenv("PATH")` would therefore give two different answers about the same
  /// machine depending on how the app happened to be opened, which is the one
  /// property a diagnostic must not have. So the list is written down instead:
  /// the same places on every Mac, whatever opened Vigil.
  ///
  /// And a written list is still not the user's `PATH`. It cannot be. People
  /// run agents through `npx`, `bunx`, `mise`, `asdf`, a nix shell, a
  /// project-local `node_modules/.bin`, a shell alias or a wrapper script, and
  /// several of those leave nothing on disk to find. Reading the user's real
  /// `PATH` would mean running their login shell — their rc files, from a menu
  /// bar app, with a startup that can take seconds on a machine with `nvm` —
  /// and it would still miss every per-project case.
  ///
  /// Which is why nothing here concludes anything from *absence*. The list only
  /// has to be good enough to find copies that are there; `HostHookSupport`
  /// treats finding nothing as a reason to say nothing.
  private static var searchDirectories: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
      // Homebrew, both architectures, and MacPorts.
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/opt/local/bin",
      // launchd's own, so a host installed the system way is still seen.
      "/usr/bin",
      // Per-user install prefixes, in rough order of how common they are for
      // the four hosts Vigil ships integrations for.
      "\(home)/.local/bin",
      "\(home)/bin",
      "\(home)/.bun/bin",
      "\(home)/.deno/bin",
      "\(home)/.cargo/bin",
      "\(home)/.volta/bin",
      "\(home)/.yarn/bin",
      "\(home)/.npm-global/bin",
      "\(home)/.npm-packages/bin",
      // Version managers keep a shim directory that is on the user's `PATH`
      // whether or not the tool behind it is installed. A shim resolves to the
      // manager rather than to a release, so it dates as unknown — which reads
      // as a reason to stay quiet, exactly as it should.
      "\(home)/.asdf/shims",
      "\(home)/.local/share/mise/shims",
      "\(home)/.rbenv/shims",
    ]
  }

  // MARK: - The cache

  private struct Measurement {
    let support: HostHookSupport
    let at: Date
  }

  private static var cached: [AgentKind: Measurement] = [:]

  /// How long a measurement stands before it is taken again.
  ///
  /// The invalidation story has two halves, because the two things that change
  /// the answer are not the same kind of event.
  ///
  /// One is Vigil's own doing — an install or an uninstall — and that calls
  /// `invalidate()` directly, the way `HelperDrift` is invalidated after the
  /// clamshell helper is replaced.
  ///
  /// The other is the user updating their agent, which Vigil has no way to
  /// observe and which is precisely what this notice asks them to go and do. A
  /// cache held for the life of the process would leave the notice standing
  /// after they had done it, and an instruction that goes on being given after
  /// it has been followed is the "press Update and watch nothing change"
  /// failure wearing a different hat. So the measurement ages out. Ten minutes
  /// is long enough that a panel opened repeatedly measures once, and short
  /// enough that someone who updates a host and comes back finds the notice
  /// gone without restarting Vigil.
  ///
  /// Affordable because the measurement never runs anything: a handful of
  /// `stat` calls, one symlink resolution and at most one small JSON read per
  /// host. Running `gemini --version` would have been the obvious way to date a
  /// copy and is the reason this does not — it costs the better part of a
  /// second of CPU per host, and a menu bar app has no business starting
  /// somebody's coding agent because they opened a panel.
  static let recheckAfter: TimeInterval = 10 * 60

  /// Whether every copy of this host Vigil can see is too old to run our hooks.
  static func support(for integration: AgentIntegration) -> HostHookSupport {
    guard let floor = integration.hookFloor else { return .notChecked }

    if let measurement = cached[integration.id],
      Date().timeIntervalSince(measurement.at) < recheckAfter
    {
      return measurement.support
    }

    let copies = self.copies(of: floor.executable)
    let support = HostHookSupport.verdict(copies: copies, floor: floor)
    cached[integration.id] = Measurement(support: support, at: Date())

    if case .tooOld = support {
      // Logged as well as surfaced, and this is where the paths go. The
      // sentence the user reads names versions only — DESIGN.md keeps that
      // much detail out of a fixed-height window — but the one question a bug
      // report has to answer is *which* copy Vigil was looking at.
      let found = copies.map { "\($0.path)=\($0.version?.text ?? "unknown")" }
        .joined(separator: ", ")
      log.notice(
        """
        every copy of \(floor.executable, privacy: .public) found predates \
        \(floor.since.text, privacy: .public): \(found, privacy: .public)
        """)
    }
    return support
  }

  /// Throw the cached answers away. Called after anything that installs or
  /// removes hooks, so a notice does not outlive the thing it is about.
  static func invalidate() { cached.removeAll() }

  // MARK: - Looking

  /// Every copy of `executable` the search list holds, one per real file.
  ///
  /// Keyed on the resolved path, so a command reachable through two symlinks —
  /// which is the normal shape of a Homebrew install — is one copy rather than
  /// two, and a Mac holding one old install does not read as holding several.
  private static func copies(of executable: String) -> [HostCopy] {
    var seen = Set<String>()
    var found: [HostCopy] = []

    for directory in searchDirectories {
      let candidate = (directory as NSString).appendingPathComponent(executable)
      guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }

      let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
      guard seen.insert(resolved).inserted else { continue }

      found.append(HostCopy(path: candidate, version: version(ofResolved: resolved)))
    }
    return found
  }

  // MARK: - Dating a copy without running it

  /// The version an install layout declares, or nil when it declares none.
  ///
  /// Read off the filesystem rather than asked for, which is the whole reason
  /// this check is cheap enough to run on a panel open. Two layouts account for
  /// every copy of the hosts Vigil integrates with that has been seen on a Mac,
  /// and both are structural — a directory shape the packaging tool creates,
  /// not a string that happens to look like a version.
  ///
  /// Anything else dates as nil, which `HostHookSupport` reads as a reason to
  /// stay quiet. A wrapper script, a single-file binary and a version-manager
  /// shim are all perfectly healthy installs, and none of them writes its
  /// version anywhere Vigil can read it.
  private static func version(ofResolved path: String) -> HostVersion? {
    npmPackageVersion(near: path) ?? cellarVersion(in: path)
  }

  /// The `version` in the `package.json` of the npm package this file belongs
  /// to.
  ///
  /// Walks up from the resolved file, because a package's entry point sits at
  /// a depth the package chooses — `dist/index.js` on one release of Gemini
  /// CLI and `bundle/gemini.js` on another.
  ///
  /// Only accepts a `package.json` under a `node_modules` directory, and that
  /// guard is doing real work. Walking up far enough from a command in
  /// `~/.local/bin` reaches the home directory, and a stray `package.json`
  /// there would date an unrelated binary with an unrelated project's version
  /// number — a confident wrong answer of exactly the kind this whole change
  /// removes. `node_modules` in the path is the signature of an actual package
  /// install and nothing else has it.
  private static func npmPackageVersion(near path: String) -> HostVersion? {
    var directory = (path as NSString).deletingLastPathComponent
    // Four levels covers `…/node_modules/@scope/name/dist/index.js` with one to
    // spare, and stops well short of anybody's home directory.
    for _ in 0..<5 {
      guard directory.contains("/node_modules/") else { break }
      let manifest = (directory as NSString).appendingPathComponent("package.json")
      if let version = versionInManifest(at: manifest) { return version }
      let parent = (directory as NSString).deletingLastPathComponent
      guard parent != directory else { break }
      directory = parent
    }
    return nil
  }

  /// The `version` string in one `package.json`, if it holds a readable one.
  private static func versionInManifest(at path: String) -> HostVersion? {
    guard let data = FileManager.default.contents(atPath: path),
      // A package manifest is a few kilobytes. A larger file under that name is
      // something else, and reading it into memory to find out is not worth a
      // version number.
      data.count <= 256 * 1024,
      let object = try? JSONSerialization.jsonObject(with: data),
      let manifest = object as? [String: Any],
      let raw = manifest["version"] as? String
    else { return nil }
    return HostVersion(raw)
  }

  /// The version in a Homebrew Cellar path — `…/Cellar/<formula>/<version>/…`.
  ///
  /// The fallback for a formula that is not a Node package, and the reading
  /// Homebrew itself relies on: the version is the directory name, and the
  /// `bin` symlink pointing into it is how `brew` switches between installed
  /// versions.
  private static func cellarVersion(in path: String) -> HostVersion? {
    let parts = (path as NSString).pathComponents
    guard let cellar = parts.firstIndex(of: "Cellar"),
      // Cellar, then the formula, then the version.
      cellar + 2 < parts.count
    else { return nil }
    return HostVersion(parts[cellar + 2])
  }
}
