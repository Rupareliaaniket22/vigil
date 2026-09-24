import Foundation
import OSLog
import VigilCore

/// Installs Vigil's hook into Claude Code's settings.
///
/// This edits a file the user did not ask us to touch, so it backs up first,
/// writes atomically, and never rewrites anything it cannot parse.
struct HookInstaller {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "installer")

  /// Paths are injected so the whole install/uninstall cycle can be exercised
  /// against a temporary directory. This code rewrites someone's editor
  /// settings; it should not be the one part that is never run before shipping.
  let scriptPath: String
  let settingsPath: String
  let integration: AgentIntegration

  /// The home directory the paths this installer is *not* given are resolved
  /// against: the other three agents' settings files, which `uninstall()`
  /// consults before deleting the shared script, and Codex's `config.toml`.
  ///
  /// A parameter rather than a read of `homeDirectoryForCurrentUser`, because
  /// those are the reads a test cannot otherwise redirect. Exercising the
  /// delete rule used to mean moving the whole process's idea of home with
  /// `CFFIXED_USER_HOME` — a global, so every suite touching it had to hold a
  /// lock and run serially, and a redirect that silently failed ran the
  /// scenario against the developer's real `~/.claude`, `~/.codex`, `~/.gemini`
  /// and `~/.cursor`. Passed in, the fake home is visible in the call and
  /// cannot leak past it.
  let home: URL

  /// Spelled out rather than left to the memberwise initializer so that `home`
  /// can default: the app always wants the real one, and only a test ever says
  /// otherwise.
  init(
    scriptPath: String,
    settingsPath: String,
    integration: AgentIntegration,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.scriptPath = scriptPath
    self.settingsPath = settingsPath
    self.integration = integration
    self.home = home
  }

  /// One installer per agent Vigil knows about.
  static func live(
    for integration: AgentIntegration,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> HookInstaller {
    HookInstaller(
      scriptPath: defaultScriptPath(home: home),
      settingsPath: settingsPath(for: integration, home: home),
      integration: integration,
      home: home
    )
  }

  /// Where this agent keeps its settings, under `home`.
  ///
  /// `home` has no default on purpose. Every caller inside this file already
  /// has one to pass, and a default would make the real user's home the thing
  /// that happens when you say nothing — which is precisely the mistake a test
  /// makes once and never notices.
  static func settingsPath(for integration: AgentIntegration, home: URL) -> String {
    home.appendingPathComponent(integration.settingsPath).path
  }

  enum InstallError: LocalizedError {
    case scriptMissingFromBundle
    case settingsUnreadable(String)
    case settingsHasComments(String)
    case settingsNotWritable(String)
    case settingsShapeUnknown(String, [String])
    case trustNotOffered(String)
    case trustRecordUnfamiliar(String, String)
    case trustConfigUnfamiliar(String, String)
    case trustConfigUnreadable(String)

    var errorDescription: String? {
      switch self {
      case .scriptMissingFromBundle:
        "Vigil's hook script is missing from the app bundle. Reinstall Vigil."
      case .settingsUnreadable(let path):
        "Couldn't read \(path). Vigil left it untouched — check it is valid JSON."
      case .settingsShapeUnknown(let path, let keys):
        // The alternative was to overwrite whatever is there, which is how a
        // hook belonging to another tool would disappear without anyone being
        // told. Name the entries so the user can go and look at them.
        "\(path) holds \(keys.count == 1 ? "a hook entry" : "hook entries") Vigil "
          + "doesn't recognise (\(keys.joined(separator: ", "))). Vigil left "
          + "\(keys.count == 1 ? "it" : "them") alone rather than replace "
          + "\(keys.count == 1 ? "it" : "them") — add Vigil's hook by hand, or move "
          + "that entry out of the way and try again."
      case .settingsHasComments(let path):
        // Naming the real reason matters: the host accepts comments, so the
        // user's editor shows nothing wrong and "invalid JSON" reads as a lie.
        "\(path) has comments in it, which Vigil can't edit without deleting "
          + "them. Remove the comments and try again, or add the hook by hand."
      case .settingsNotWritable(let path):
        "\(path) is read-only. Vigil left it alone — make it writable and try again."
      case .trustNotOffered(let host):
        // Reached when the hooks cannot be identified well enough to say what
        // approving them would mean. Vigil approves only what it can prove it
        // wrote, so there is nothing here it may touch — send the user to the
        // host's own review command, where the entry can be looked at.
        "Vigil couldn't work out exactly what \(host) would be approving, so it "
          + "wrote nothing. Open \(host) and run /hooks to review the hooks there."
      case .trustRecordUnfamiliar(let path, let host):
        // TOML rejects a file that defines a key twice, and a config.toml
        // Codex cannot parse costs the user Codex — a far worse outcome than
        // the one being fixed. Refusing is the whole of CodexTrustWriter's
        // position; this is where the user hears about it.
        "\(path) already records that hook in a form Vigil can't rewrite safely. "
          + "Vigil changed nothing — open \(host) and run /hooks to approve them there."
      case .trustConfigUnfamiliar(let path, let host):
        // Not the same sentence as `trustRecordUnfamiliar`: there is no record
        // of ours in the way, the file itself holds something Vigil couldn't
        // account for — so "already records that hook" would send the user
        // looking for a record that isn't there.
        "Vigil couldn't read all of \(path) with confidence, so it changed "
          + "nothing rather than risk writing a file \(host) can't parse. "
          + "Open \(host) and run /hooks to approve them there."
      case .trustConfigUnreadable(let path):
        "Couldn't read \(path). Vigil left it untouched."
      }
    }
  }

  /// Where the hook script lives once installed.
  ///
  /// Copied out of the bundle rather than referenced inside it, so moving or
  /// replacing the app doesn't break a hook Claude Code has already recorded.
  ///
  /// Takes the home for the reason `settingsPath(for:home:)` does, and has no
  /// default for the same one: this is the path an uninstall deletes.
  static func defaultScriptPath(home: URL) -> String {
    home.appendingPathComponent(".vigil/hooks/vigil-hook.sh").path
  }

  var isInstalled: Bool { missingEvents.isEmpty }

  /// Which events we expect a hook for and did not find one.
  ///
  /// Empty means installed. A missing script counts as everything missing,
  /// because a hook entry pointing at a file that is not there fires nothing.
  var missingEvents: [String] {
    guard FileManager.default.isExecutableFile(atPath: scriptPath),
      let settings = try? Self.readSettings(at: settingsPath)
    else { return integration.allEvents }
    return HookConfiguration.missingEvents(
      in: settings, scriptPath: scriptPath, integration: integration)
  }

  /// Hooks of ours still registered for events Vigil has stopped listening for.
  ///
  /// Non-empty means an install written by an older version. Re-running the
  /// install sweeps them; until then they keep firing, which for the Cursor
  /// permission hooks that were retired means they keep blocking the agent.
  /// A missing script counts as none, because nothing is firing either way.
  var retiredEvents: [String] {
    guard FileManager.default.isExecutableFile(atPath: scriptPath),
      let settings = try? Self.readSettings(at: settingsPath)
    else { return [] }
    return HookConfiguration.retiredEvents(
      in: settings, scriptPath: scriptPath, integration: integration)
  }

  /// Hooks of ours whose command is not the one Vigil writes today.
  ///
  /// Non-empty means an install written by an older version, the same as
  /// `retiredEvents` — but found by reading the entry rather than by noticing
  /// which event it sits under, which is the only way to see a hook that is
  /// registered for exactly the right events and says the wrong thing. A
  /// missing script counts as none, on the same reasoning: nothing is firing
  /// either way.
  var outdatedEvents: [String] {
    guard FileManager.default.isExecutableFile(atPath: scriptPath),
      let settings = try? Self.readSettings(at: settingsPath)
    else { return [] }
    return HookConfiguration.outdatedEvents(
      in: settings, scriptPath: scriptPath, integration: integration)
  }

  /// Whether the host will run the hooks we installed.
  ///
  /// `.notRequired` for three of the four. For Codex it reads
  /// `~/.codex/config.toml`, because Codex files its trust decisions there
  /// rather than beside the hooks — the one place in this file where answering
  /// a question about one agent means opening a second file.
  ///
  /// Read-only. Writing a record is `recordTrust(_:)`, and the only list that
  /// may be handed to it is `selfWrittenTrustRecords()` — entries Vigil can
  /// prove it wrote itself, byte for byte. Nothing else is ever approved, by
  /// Vigil or through it; see that function for why writing those without
  /// asking is not the self-approval it looks like.
  ///
  /// A missing script is the same "nothing is firing either way" case
  /// `retiredEvents` treats as empty, and an absent `config.toml` is a Codex
  /// that has never been asked about anything — which is untrusted, not
  /// unknown, and `status` reaches that conclusion on its own from a file with
  /// no records in it.
  var trustState: HookTrustState {
    guard integration.requiresHookTrust else { return .notRequired }
    guard FileManager.default.isExecutableFile(atPath: scriptPath),
      let settings = try? Self.readSettings(at: settingsPath)
    else { return .unknown }

    let toml = (try? Self.readTrustConfig(at: codexConfigFilePath)) ?? ""

    return CodexHookTrust.status(
      hooks: settings,
      // Codex keys trust on the path *it* resolved the hooks file to, so this
      // has to be the same string it printed — the settings path as given, not
      // the symlink-resolved one `writeSettings` uses.
      hooksPath: settingsPath,
      configTOML: toml,
      scriptPath: scriptPath,
      integration: integration
    )
  }

  /// Where Codex keeps its hook trust records, relative to home.
  static let codexConfigPath = ".codex/config.toml"

  /// The same file, resolved against this installer's home.
  ///
  /// Everything in this type that reads or writes that file goes through here,
  /// never through the static below — it is the one path an installer writes
  /// that it is not handed, so it is the one a test most needs moved.
  var codexConfigFilePath: String {
    home.appendingPathComponent(Self.codexConfigPath).path
  }

  /// The same file for whoever is running the app, for showing them where it
  /// is. Not for reading or writing: that is the instance property above.
  static var codexConfigFilePath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(codexConfigPath).path
  }

  // MARK: - Install

  func install() throws {
    try copyScript()

    var settings = try Self.readSettings(at: settingsPath)

    // Checked before writing anything: `HookConfiguration.install` skips what
    // it cannot merge into rather than overwriting it, which is the safe half
    // of the answer. This is the other half — a half-wired agent that nobody
    // was told about is how "my hooks stopped firing" starts.
    let blocked = HookConfiguration.unmergeableKeys(in: settings, integration: integration)
    guard blocked.isEmpty else {
      throw InstallError.settingsShapeUnknown(settingsPath, blocked)
    }

    settings = HookConfiguration.install(
      into: settings, scriptPath: scriptPath, integration: integration)
    try Self.writeSettings(settings, to: settingsPath)

    Self.log.info("hooks installed into \(settingsPath, privacy: .public)")
  }

  func uninstall() throws {
    var settings = try Self.readSettings(at: settingsPath)
    settings = HookConfiguration.uninstall(from: settings, scriptPath: scriptPath)
    try Self.writeSettings(settings, to: settingsPath)

    // One script serves every agent, so deleting it here would break the hooks
    // of every *other* agent still installed. Remove it only once nothing
    // points at it any more — and only when that is *known*, never merely
    // unrefuted. `.unknown` means some other agent's settings file would not
    // read, which is exactly where a reference we must not break would be
    // hiding, so it keeps the script.
    //
    // The two mistakes are not comparable. Leaving an orphaned script behind
    // costs three kilobytes in a directory nobody looks at, and the next
    // install overwrites it. Deleting a live one leaves every other agent with
    // hook entries that still read as correct, pointing at a file that is not
    // there: nothing fires, nothing in any settings file hints at why, and the
    // first anyone hears of it is a Mac that slept in the middle of a run.
    if Self.anyIntegrationReferencesScript(at: scriptPath, home: home) == .notReferenced {
      try? FileManager.default.removeItem(atPath: scriptPath)
    }
    Self.log.info("hooks removed for \(integration.displayName, privacy: .public)")
  }

  /// Whether an agent's settings still point at the shared hook script.
  ///
  /// Three answers rather than two, and the third is the whole reason this is
  /// not a `Bool`. A settings file that will not read might hold a reference
  /// or might not, and the only honest thing to say about it is that we do not
  /// know. Answering "no" on its behalf is how a file nobody could read gets
  /// counted as a file with nothing in it.
  enum ScriptReference: Equatable {
    /// The settings file reads, and points at the script.
    case referenced
    /// The settings file reads, and does not.
    case notReferenced
    /// The settings file did not read, so the question went unanswered.
    case unknown
  }

  /// Whether any agent's settings still point at `scriptPath`.
  ///
  /// Deliberately a weaker question than `isInstalled`, and the difference is
  /// load-bearing. Widening Vigil's expected event set makes every install
  /// written by an earlier version read as incomplete; asking "is anyone fully
  /// installed" would then answer no, and uninstalling one agent would delete
  /// the shared script out from under three agents that were working fine.
  ///
  /// `.referenced` wins over `.unknown`, and `.unknown` over `.notReferenced`:
  /// one agent that certainly uses the script settles it, and failing that,
  /// one agent we could not ask is enough to leave the question open. Only
  /// four clean "no"s produce a `.notReferenced`.
  ///
  /// Takes the path rather than assuming the default one, so it answers the
  /// question its caller is actually asking. An installer pointed at a script
  /// somewhere else — the install/uninstall check in `AppDelegate` runs against
  /// a temporary directory — would otherwise have the fate of its own script
  /// decided by whether this user's real settings still reference the real one.
  ///
  /// Takes the home for the same reason: four settings files are read here, and
  /// which four is the whole question.
  static func anyIntegrationReferencesScript(at scriptPath: String, home: URL)
    -> ScriptReference
  {
    var anyUnreadable = false
    for integration in AgentIntegration.all {
      let installer = HookInstaller(
        scriptPath: scriptPath,
        settingsPath: settingsPath(for: integration, home: home),
        integration: integration,
        home: home
      )
      switch installer.scriptReference {
      case .referenced: return .referenced
      case .unknown: anyUnreadable = true
      case .notReferenced: continue
      }
    }
    return anyUnreadable ? .unknown : .notReferenced
  }

  /// Whether this agent's settings mention our script at all.
  ///
  /// Every refusal `readSettings` raises is an `.unknown` here: malformed
  /// JSON, a JSON comment, a root that is not an object, a file that will not
  /// open, a directory that will not be searched. A `try?` collapsed all of
  /// them into `false`, and `false` from here is a licence to delete a file
  /// three other agents are using.
  var scriptReference: ScriptReference {
    guard let settings = try? Self.readSettings(at: settingsPath) else { return .unknown }
    let missing = HookConfiguration.missingEvents(
      in: settings, scriptPath: scriptPath, integration: integration)
    return missing.count < integration.allEvents.count ? .referenced : .notReferenced
  }

  // MARK: - Trust

  /// The approvals Vigil may record, which is often an empty list.
  ///
  /// Everything that decides *which* entries qualify is in
  /// `CodexTrustWriter.selfWrittenRecords`, beside the comparison it makes and
  /// inside the tests that pin it. This is only the file handling: a missing
  /// script means nothing is firing either way, and an unreadable settings file
  /// means nothing here can be claimed about it. Both answer "nothing", which
  /// leaves the state untrusted and the row in front of the user.
  ///
  /// Empty is not a failure and is never reported as one. It means Vigil has
  /// nothing it can approve, which is the safe half of every ambiguity this
  /// path can meet: the host goes on refusing, and the interface says so.
  func selfWrittenTrustRecords() -> [CodexTrustWriter.Record] {
    guard integration.requiresHookTrust,
      FileManager.default.isExecutableFile(atPath: scriptPath),
      let settings = try? Self.readSettings(at: settingsPath)
    else { return [] }

    return CodexTrustWriter.selfWrittenRecords(
      hooks: settings,
      // The path as given, never the symlink-resolved one — same rule, and the
      // same reason, as `trustState`.
      hooksPath: settingsPath,
      scriptPath: scriptPath,
      integration: integration
    )
  }

  /// Write approvals into the host's trust file.
  ///
  /// Takes the records rather than deriving them, so that the list this writes
  /// is the list its caller filtered — this must never be able to widen it.
  /// `CodexTrustWriter.apply` returns every other byte of `config.toml`
  /// unchanged and refuses the shapes it cannot rewrite, which leaves this with
  /// only the file handling to get right — and that is `writeReplacing`, the
  /// same backup and atomic rename a settings file gets.
  func recordTrust(_ records: [CodexTrustWriter.Record]) throws {
    let path = codexConfigFilePath
    let current = try Self.readTrustConfig(at: path)

    let updated: String
    do {
      updated = try CodexTrustWriter.apply(records, to: current)
    } catch CodexTrustWriter.Refusal.unfamiliarRecord {
      throw InstallError.trustRecordUnfamiliar(path, integration.displayName)
    } catch CodexTrustWriter.Refusal.unfamiliarConfig {
      throw InstallError.trustConfigUnfamiliar(path, integration.displayName)
    } catch {
      throw InstallError.trustNotOffered(integration.displayName)
    }

    try Self.writeReplacing(path, with: Data(updated.utf8))
    Self.log.info("trust recorded for \(integration.displayName, privacy: .public)")
  }

  // MARK: - Files

  /// An absent `config.toml` is an empty one: a Codex with no trust records at
  /// all is one that will run no hooks, which is a fact rather than an error.
  private static func readTrustConfig(at path: String) throws -> String {
    guard FileManager.default.fileExists(atPath: path) else { return "" }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw InstallError.trustConfigUnreadable(path)
    }
    return text
  }

  private func copyScript() throws {
    guard
      let source = Bundle.main.url(forResource: "vigil-hook", withExtension: "sh")
    else { throw InstallError.scriptMissingFromBundle }

    let destination = URL(fileURLWithPath: scriptPath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: scriptPath) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
  }

  /// An absent settings file is an empty one — first run is not an error.
  ///
  /// `stat` rather than `fileExists`, because `fileExists` answers false both
  /// for "there is nothing here" and for "the directory above this one cannot
  /// be searched", and to a caller deciding whether to delete shared state
  /// those mean opposite things. Only `ENOENT` and `ENOTDIR` are an absence.
  /// Anything else falls through to the read below, which throws rather than
  /// reporting a settings file with nothing in it.
  private static func readSettings(at path: String) throws -> [String: Any] {
    var info = stat()
    if stat(path, &info) != 0, errno == ENOENT || errno == ENOTDIR { return [:] }

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    // A file holding nothing but a newline is an empty one, not a broken one.
    // Refusing it sent the user looking for a syntax error in a blank file.
    let text = String(decoding: data, as: UTF8.self)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }

    guard let object = try? JSONSerialization.jsonObject(with: data),
      let settings = object as? [String: Any]
    else {
      // Refuse rather than overwrite something we can't understand — but say
      // which kind of "can't understand" it is.
      if SettingsFile.containsComments(text) {
        throw InstallError.settingsHasComments(path)
      }
      throw InstallError.settingsUnreadable(path)
    }
    return settings
  }

  private static func writeSettings(_ settings: [String: Any], to path: String) throws {
    // withoutEscapingSlashes matters: Foundation writes "\/Users\/..." by
    // default, which is valid JSON but makes a hand-edited settings file uglier
    // than we found it and produces noisy diffs for anyone versioning dotfiles.
    //
    // sortedKeys is a lesser evil rather than a good one. Serializing a
    // dictionary reorders keys either way, so the choice is between a stable
    // order and a different arbitrary one on every write; stable at least means
    // a second write produces no diff.
    let data = try JSONSerialization.data(
      withJSONObject: settings,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try writeReplacing(path, with: data)
  }

  /// Put `data` where `path` is, keeping what was there safe.
  ///
  /// Every rule below is about editing a file Vigil does not own, so all of
  /// them apply to all of them: `config.toml` goes through here rather than
  /// growing its own copy, because each failure these prevent is the same
  /// failure in someone's TOML as in their JSON.
  private static func writeReplacing(_ path: String, with data: Data) throws {
    // Follow a symlink to its target before writing. `.atomic` renames over the
    // path, which would replace a link into someone's dotfiles repo with a
    // regular file and leave the real file stale.
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let exists = FileManager.default.fileExists(atPath: url.path)

    // An atomic write renames a new file over the old one, so it succeeds on a
    // file the user deliberately made read-only — the mode belongs to the file
    // being replaced, not to the directory doing the replacing. Refuse instead:
    // chmod 444 on a settings file is someone saying "don't touch this".
    if exists, !FileManager.default.isWritableFile(atPath: url.path) {
      throw InstallError.settingsNotWritable(url.path)
    }

    // Nothing to do. Worth checking because Vigil reformats what it writes, and
    // reformatting someone's version-controlled dotfiles to change nothing is a
    // diff they have to read and then discard.
    if exists, let current = try? Data(contentsOf: url), current == data { return }

    // Keep the user's *original* file, once. Overwriting the backup on every
    // write meant that after install-then-uninstall the "backup" was our own
    // post-install output rather than what they started with. A backup that
    // cannot be written aborts the edit rather than proceeding unprotected.
    let backup = url.path + ".vigil-backup"
    if exists, !FileManager.default.fileExists(atPath: backup) {
      try FileManager.default.copyItem(atPath: url.path, toPath: backup)
    }

    // Carry the original mode across. The atomic rename installs a brand-new
    // file, so a settings file the user had at 0600 would come back 0644 —
    // quietly widening the permissions on a file that can hold API keys.
    //
    // A mode that cannot be read falls back to 0600 rather than to whatever
    // the umask gives: the failure worth avoiding is the widening one, so the
    // guess has to be the tight one. Only the owner ever needs to read any of
    // these files.
    let mode: NSNumber? =
      exists
      ? ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        as? NSNumber ?? NSNumber(value: 0o600))
      : nil

    // Atomic, so an interrupted write can't truncate the file.
    try data.write(to: url, options: .atomic)

    if let mode {
      try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
  }
}
