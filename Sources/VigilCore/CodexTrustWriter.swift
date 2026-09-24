import Foundation

/// Writes Codex's trust records for the hook entries Vigil wrote itself.
///
/// Codex drops any hook it has no matching `trusted_hash` for, so a hook Vigil
/// has installed perfectly is a hook Codex ignores until something approves it.
/// This type is what approves it — without asking, every time, for Vigil's own
/// entries and for nothing else.
///
/// That is a reversal, and the reasoning it replaces is worth stating so nobody
/// reinstates it by accident. The old position was that a program which
/// approves itself has removed the gate for everyone, "including for a later
/// version of itself whose script has been changed". The second half of that is
/// simply false: Codex hashes the hook **entry** — event name, command string,
/// timeout, matcher — and not the contents of the script the command points at.
/// `CodexHookTrust.identityJSON` is the whole of what is hashed, and
/// `vigil-hook.sh` does not appear in it. Editing that script has never
/// invalidated a `trusted_hash` and never could. So the gate was not protecting
/// the user against Vigil, and the thing it does protect against — an entry
/// turning up in `hooks.json` that the user did not get — is untouched here,
/// because `selfWrittenRecords` will not write a record for an entry whose
/// command is not byte-for-byte the one this version of Vigil installs.
///
/// What the old position cost was real: every Vigil release that changed a
/// command invalidated every hash, and the user was asked to decide again
/// something they had already decided. A prompt that fires on every release is
/// a prompt people learn to dismiss, which leaves them less protected than one
/// they read once — and in this case less protected than none at all, because
/// the one they are dismissing is the one that matters.
///
/// So: no prompt, and the whole safeguard is the comparison in
/// `selfWrittenRecords`. It is not invisible, though. The settings row says
/// when Vigil recorded a host's approval, the panel says so when it happens,
/// and one switch turns it off.
///
/// Everything here is string surgery on a file Vigil does not own. Each rule
/// below exists because the failure it prevents is worse than not writing at
/// all: a `config.toml` Codex cannot parse does not cost the user their wake
/// lock, it costs them Codex.
public enum CodexTrustWriter {

  /// One approval: the key Codex files it under, and what it should say.
  public struct Record: Sendable, Equatable {
    public let key: String
    public let hash: String
    /// Carried so the interface can name what is being approved. Codex's key
    /// is a path and three numbers, which tells a reader nothing at all.
    public let event: String

    public init(key: String, hash: String, event: String) {
      self.key = key
      self.hash = hash
      self.event = event
    }
  }

  /// Why Vigil would rather write nothing.
  public enum Refusal: Error, Equatable {
    /// A record for this key exists in a shape this writer does not produce —
    /// a dotted key under `[hooks.state]`, or an inline table. Rewriting it
    /// means either editing a form we do not fully understand or appending a
    /// second definition of the same key, and TOML rejects a file that defines
    /// a key twice. Codex would then run none of the user's hooks, from any
    /// tool, which is a far worse outcome than the one being fixed.
    case unfamiliarRecord(key: String)
    /// The file as a whole holds something this scanner could not account for
    /// — a value that never ends, a header it cannot read unambiguously, or
    /// `hooks` / `hooks.state` written as an inline table or an array of
    /// tables, either of which closes the namespace our header would extend.
    /// Separate from `unfamiliarRecord` because it names no key: the problem
    /// is not one record we would have to rewrite, it is that nothing in the
    /// file can be located with confidence, so there is no safe edit at all.
    case unfamiliarConfig
    /// A hash could not be computed for at least one entry, so approving the
    /// rest would half-fix it and report success.
    case cannotIdentifyHooks
  }

  /// Every approval that would make Codex run the hooks of ours in this file,
  /// whether Vigil wrote them or not.
  ///
  /// The unfiltered description, and deliberately **not** what anything writes:
  /// `selfWrittenRecords` is the list with a bound on it, and it is the only
  /// one `HookInstaller.recordTrust` is ever handed. This one stays because it
  /// is what that function narrows — the two are read side by side, and a
  /// narrowing with nothing to compare against is a claim with no control — and
  /// because the round-trip tests drive `apply` through it against a file no
  /// version of Vigil wrote.
  ///
  /// Nil rather than a partial list when anything cannot be identified: a list
  /// missing an entry would describe the file as smaller than it is.
  public static func records(
    hooks settings: [String: Any],
    hooksPath: String,
    scriptPath: String,
    integration: AgentIntegration
  ) -> [Record]? {
    guard integration.requiresHookTrust,
      let ours = CodexHookTrust.entries(
        in: settings, scriptPath: scriptPath, integration: integration),
      !ours.isEmpty
    else { return nil }

    var records: [Record] = []
    for entry in ours {
      guard
        let key = CodexHookTrust.stateKey(
          hooksPath: hooksPath, event: entry.event, group: entry.group, handler: entry.handler),
        let hash = CodexHookTrust.identityHash(
          event: entry.event, command: entry.command, timeoutSeconds: entry.timeoutSeconds,
          matcher: entry.matcher)
      else { return nil }
      records.append(Record(key: key, hash: hash, event: entry.event))
    }
    return records
  }

  /// The approvals Vigil may record, and no others.
  ///
  /// The narrow sibling of `records`. That one describes whatever is in the
  /// file; this one is filtered down to entries Vigil can prove it wrote
  /// itself, and it is the only list that is ever written.
  ///
  /// The rule is one line long and everything else here is in service of it:
  /// an entry qualifies only when its command is **byte-for-byte** what
  /// `HookConfiguration.command(scriptPath:integration:registration:)` produces
  /// today for this integration, under the event it is filed under, with the
  /// matcher that registration carries. Not "looks like ours", not "names our
  /// script" — `HookConfiguration.isVigilHook` matches the script's filename
  /// and is deliberately loose, which is right for deciding what to sweep and
  /// catastrophically wrong for deciding what to approve. An entry that fails
  /// the comparison gets no record, stays untrusted, and shows up in the
  /// interface for a human to look at, which is the outcome this whole gate is
  /// for.
  ///
  /// Why this may be written with nobody asked: see the reasoning on the type
  /// above. In one line — the hash covers the entry and not the script, so an
  /// approval limited to entries Vigil would itself write cannot sanction
  /// anything an attacker introduced. A changed command fails the comparison by
  /// construction; an unchanged one is the string Vigil installs.
  ///
  /// Which makes this comparison the entire safeguard, and it is why it is
  /// spelled out rather than expressed as a helpful predicate somewhere else.
  /// Everything above it decides *whether* to try; only this decides *what*.
  ///
  /// Returns an empty list — never a partial guess — whenever the question
  /// cannot be answered at all: a host with no trust gate, a `hooks.json`
  /// carrying a key we cannot hash, or an event Codex has no name for.
  public static func selfWrittenRecords(
    hooks settings: [String: Any],
    hooksPath: String,
    scriptPath: String,
    integration: AgentIntegration
  ) -> [Record] {
    guard integration.requiresHookTrust,
      // Vigil writes no `timeout` for the one host that gates hooks, so
      // `defaultTimeoutSeconds` has the whole answer for what it writes. The
      // field is spelled in milliseconds and Codex reads the key as seconds, so
      // a gating host that grew one would need that unit resolved before
      // anything here could claim to know the bytes. Refuse rather than guess:
      // the cost is one press, and the cost of guessing is a hash Vigil has no
      // business writing.
      integration.timeoutMilliseconds == nil,
      let ours = CodexHookTrust.entries(
        in: settings, scriptPath: scriptPath, integration: integration)
    else { return [] }

    let wanted = HookConfiguration.writtenEntries(
      scriptPath: scriptPath, integration: integration)

    var records: [Record] = []
    for entry in ours {
      // The event decides which commands are allowed here at all, the matcher
      // is part of the entry Codex hashes, and the command is compared whole.
      guard
        wanted[entry.event]?.contains(
          HookConfiguration.WrittenEntry(matcher: entry.matcher, command: entry.command)) == true
      else { continue }
      // And the timeout, which is part of the hashed identity even though it is
      // absent from the file: an entry carrying a hand-written `timeout` hashes
      // differently and is not one of ours, however right the command reads.
      guard
        entry.timeoutSeconds
          == CodexHookTrust.normalisedTimeoutSeconds(
            CodexHookTrust.defaultTimeoutSeconds(for: entry.event), for: entry.event)
      else { continue }
      guard
        let key = CodexHookTrust.stateKey(
          hooksPath: hooksPath, event: entry.event, group: entry.group, handler: entry.handler),
        let hash = CodexHookTrust.identityHash(
          event: entry.event, command: entry.command, timeoutSeconds: entry.timeoutSeconds,
          matcher: entry.matcher)
      else { continue }
      records.append(Record(key: key, hash: hash, event: entry.event))
    }
    return records
  }

  /// A `config.toml` with these approvals recorded, or a refusal.
  ///
  /// Everything outside the `trusted_hash` lines this writes is returned
  /// byte-for-byte: comments, ordering, spacing, every other setting in the
  /// file — and each line's own ending, so a file saved with CRLF stays a CRLF
  /// file rather than being quietly normalised on the user's behalf. Applying
  /// the same records twice produces the same file, so a second press is
  /// harmless; that holds for every key this writer can emit, including the
  /// ones holding a bracket or a newline, because the scanner reads a key back
  /// with the same rules the writer used to spell it.
  public static func apply(_ records: [Record], to toml: String) throws -> String {
    guard !records.isEmpty else { throw Refusal.cannotIdentifyHooks }

    var lines = CodexTOML.lines(of: toml)
    let existing = try locateStandardTables(in: CodexTOML.scan(lines), for: records)
    let terminator = CodexTOML.dominantTerminator(lines)

    // Applied last-first so that an edit never shifts a range we have already
    // worked out.
    var appended: [Record] = []
    var edits: [(range: Range<Int>, record: Record)] = []

    for record in records {
      guard let table = existing[record.key] else {
        appended.append(record)
        continue
      }
      if let hash = table.hashLines {
        edits.append((hash, record))
      } else {
        let below = table.headerLine + 1
        edits.append((below..<below, record))
      }
    }

    for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
      let text = hashLine(for: edit.record)
      guard !edit.range.isEmpty else {
        // Inserted directly under the header, and given the header's own line
        // ending. A header that ended the file without one would otherwise get
        // our record welded onto it.
        let header = edit.range.lowerBound - 1
        if lines[header].terminator.isEmpty { lines[header].terminator = terminator }
        lines.insert(
          CodexTOML.Line(text: text, terminator: lines[header].terminator),
          at: edit.range.lowerBound)
        continue
      }
      // The whole statement, which is one line in every file Codex writes but
      // need not be in one a person has edited.
      lines.replaceSubrange(
        edit.range,
        with: [CodexTOML.Line(text: text, terminator: lines[edit.range.upperBound - 1].terminator)])
    }

    guard !appended.isEmpty else { return CodexTOML.joined(lines) }

    // A trailing newline before appending, so a file that did not end in one
    // does not get our table header welded onto its last line, and a blank line
    // so the table does not run straight on from someone else's setting.
    if let last = lines.last {
      if last.terminator.isEmpty { lines[lines.count - 1].terminator = terminator }
      if !last.text.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.append(CodexTOML.Line(text: "", terminator: terminator))
      }
    }
    for (offset, record) in appended.enumerated() {
      if offset > 0 { lines.append(CodexTOML.Line(text: "", terminator: terminator)) }
      lines.append(
        CodexTOML.Line(
          text: "[hooks.state.\(CodexTOML.quotedString(record.key))]", terminator: terminator))
      lines.append(CodexTOML.Line(text: hashLine(for: record), terminator: terminator))
    }
    return CodexTOML.joined(lines)
  }

  // MARK: - Reading what is already there

  private struct Table {
    let headerLine: Int
    /// The physical lines its `trusted_hash` statement occupies, if it has one.
    var hashLines: Range<Int>?
  }

  /// Where each `[hooks.state."…"]` table is, refusing every shape we could not
  /// safely rewrite.
  ///
  /// Reads `CodexTOML`'s scan — the same scan `CodexHookTrust.trustRecords`
  /// reads — for the opposite purpose: that one tolerates whatever it cannot
  /// make out and reports less, this one has to refuse it, because the cost of
  /// guessing is a `config.toml` Codex cannot parse and therefore a Codex that
  /// runs no tool's hooks at all.
  ///
  /// A header and a dotted key are the same path written two ways, so one rule
  /// finds every shape: concatenate the current table's path with the
  /// statement's. A key of ours reached any way other than by exactly one
  /// `[hooks.state."key"]` table is a key we refuse to touch — appending our
  /// own header beside a dotted key, an inline table or a second table of the
  /// same name defines that key twice, which TOML rejects outright.
  ///
  /// Refusal is scoped to the keys being written. Another tool's record in a
  /// shape we do not produce is none of our business and no obstacle: TOML is
  /// happy to see `[hooks.state."ours"]` after a `[hooks.state]` full of
  /// someone else's dotted keys.
  private static func locateStandardTables(
    in scan: CodexTOML.Scan, for records: [Record]
  ) throws -> [String: Table] {
    // A scan that stopped early says nothing about the rest of the file, and
    // "the rest of the file" is exactly where a second definition of our key
    // would hide.
    guard scan.isComplete else { throw Refusal.unfamiliarConfig }

    var tables: [String: Table] = [:]
    /// Keys reached in a shape this writer does not produce.
    var unfamiliar: Set<String> = []
    var table: [String] = []
    /// The key of the `[hooks.state."…"]` table we are inside, if any.
    var currentKey: String?

    for element in scan.elements {
      switch element {
      case .header(let path, let line):
        table = path
        currentKey = nil
        guard path.count >= 2, path[0] == "hooks", path[1] == "state" else { continue }
        if path.count == 3 {
          // A second table of the same name is already a file TOML rejects;
          // writing into either half would only make it harder to find.
          if tables[path[2]] != nil { unfamiliar.insert(path[2]) }
          tables[path[2]] = Table(headerLine: line, hashLines: nil)
          currentKey = path[2]
        } else if path.count > 3 {
          unfamiliar.insert(path[2])
        }
      case .arrayHeader(let path, _):
        table = path
        currentKey = nil
        guard path.first == "hooks" else { continue }
        guard path.count >= 3, path[1] == "state" else {
          // `[[hooks]]` or `[[hooks.state]]`: the thing our header would extend
          // is an array, and no table header can be added to one.
          throw Refusal.unfamiliarConfig
        }
        unfamiliar.insert(path[2])
      case .assignment(let path, _, let first, let last):
        if let currentKey {
          if path == ["trusted_hash"] {
            // A second one in the same table is a file TOML already rejects,
            // and replacing only the one we happened to stop on would leave
            // the other behind still saying the old thing.
            if tables[currentKey]?.hashLines != nil { unfamiliar.insert(currentKey) }
            tables[currentKey]?.hashLines = first..<(last + 1)
          } else if path.count > 1, path[0] == "trusted_hash" {
            // `trusted_hash.something = …` makes the record a table, not a
            // string, and the line we would write cannot replace it.
            unfamiliar.insert(currentKey)
          }
          continue
        }
        let full = table + path
        guard full.first == "hooks" else { continue }
        guard full.count >= 3, full[1] == "state" else {
          if full.count == 1 || full[1] == "state" {
            // `hooks = { … }` or `hooks.state = { … }`. An inline table is
            // closed for good, so no later header may extend it.
            throw Refusal.unfamiliarConfig
          }
          continue
        }
        unfamiliar.insert(full[2])
      }
    }

    // In the order the user is being shown them, so the refusal names the first
    // record they would have read rather than whichever key a Set offers up.
    for record in records where unfamiliar.contains(record.key) {
      throw Refusal.unfamiliarRecord(key: record.key)
    }
    return tables
  }

  // MARK: - Writing

  private static func hashLine(for record: Record) -> String {
    "trusted_hash = \(CodexTOML.quotedString(record.hash))"
  }
}
