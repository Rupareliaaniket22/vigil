import Foundation

/// Writes Codex's trust records for Vigil's own hooks, on the user's say-so.
///
/// Codex drops any hook it has no matching `trusted_hash` for, so a hook Vigil
/// has installed perfectly is a hook Codex ignores until a human approves it.
/// The gate exists so that a person reads a command before their agent runs it,
/// and `CodexHookTrust` deliberately never writes a record on its own — a
/// program that approves itself has removed the gate for everyone, including
/// for a later version of itself whose script has been changed.
///
/// This type is the other half of that position. The approval still has to be a
/// person's, so it is collected in Vigil's own window — the exact records shown
/// first, written only on a press — rather than taken silently on install. That
/// is the difference between asking and helping yourself, and it is the whole
/// reason this is a separate type with its own confirmation rather than a line
/// inside `install()`.
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
    /// Carried for the confirmation text. Codex's key is a path and three
    /// numbers, which tells a reader nothing about what they are approving.
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

  /// The approvals that would make Codex run Vigil's hooks.
  ///
  /// Nil rather than a partial list when anything cannot be identified: these
  /// are the exact bytes shown to the user for approval, and a list missing an
  /// entry is a consent form missing a line.
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
          event: entry.event, command: entry.command, timeoutSeconds: entry.timeoutSeconds)
      else { return nil }
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
