import Foundation
import Testing

@testable import VigilCore

/// Hostile inputs for `CodexTrustWriter` and `CodexHookTrust`.
///
/// Every test in this file **fails today**. They were found by an adversarial
/// pass and are written as the behaviour we need rather than the behaviour we
/// have, so that fixing the writer turns them green instead of requiring them
/// to be rewritten. Nothing here is hypothetical: each output was round-tripped
/// through a real TOML parser and rejected.
///
/// The invariant under test throughout is the one `CodexTrustWriter`'s own
/// documentation names as catastrophic: `apply` must never return TOML that
/// defines the same key twice. Codex refuses to parse such a file, and a
/// `config.toml` Codex cannot parse stops *every* tool's hooks — which is
/// strictly worse than the untrusted-hook problem the writer exists to fix.
///
/// The root cause of the first four is shared: `toml.split(separator: "\n")`
/// splits a Swift `String` by `Character`, and `"\r\n"` is a *single*
/// `Character` (one extended grapheme cluster). A CRLF file therefore never
/// splits at all, so the scanner sees one enormous line and finds nothing.
/// `CodexHookTrust.trustRecords` splits the same way and is blind in the same
/// places, which is what makes the writer run at all: the reader reports
/// `untrusted`, the user presses the button, and the writer appends a record
/// that is already there.
@Suite("Hostile config.toml input")
struct CodexTrustWriterHostileTests {

  private static let hooksPath = "/Users/aniket/.codex/hooks.json"
  private static let key = "\(hooksPath):stop:0:0"
  private static let newHash = "sha256:" + String(repeating: "ab", count: 32)

  private static func records(key: String = key) -> [CodexTrustWriter.Record] {
    [CodexTrustWriter.Record(key: key, hash: newHash, event: "Stop")]
  }

  private static func header(_ key: String) -> String { "[hooks.state.\"\(key)\"]" }

  /// Non-overlapping occurrences of `needle`.
  private static func count(_ needle: String, in haystack: String) -> Int {
    var found = 0
    var cursor = haystack.startIndex
    while let hit = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
      found += 1
      cursor = hit.upperBound
    }
    return found
  }

  // MARK: - Line endings

  /// A `config.toml` saved with CRLF — synced from Windows, or written by an
  /// editor configured that way. Codex parses it happily; we do not see the
  /// record that is already in it, and append a second copy of the table.
  ///
  /// Real parser verdict on today's output:
  /// `Cannot declare ('hooks', 'state', '…:stop:0:0') twice`.
  @Test("a CRLF file does not get its table defined twice")
  func crlfDoesNotDuplicateTheTable() throws {
    let toml =
      "model = \"o3\"\r\n\r\n\(Self.header(Self.key))\r\ntrusted_hash = \"sha256:old\"\r\n"
    let out = try CodexTrustWriter.apply(Self.records(), to: toml)
    #expect(Self.count(Self.header(Self.key), in: out) == 1)
  }

  /// The reader half of the same bug. Nothing is written here — but this is
  /// what sends the user to the button in the first place, so a fix that only
  /// repairs the writer would still report a correctly trusted hook as
  /// untrusted forever.
  @Test("a CRLF file's existing trust records are visible to the reader")
  func crlfRecordsAreRead() {
    let toml = "\(Self.header(Self.key))\r\ntrusted_hash = \"sha256:old\"\r\n"
    #expect(CodexHookTrust.trustRecords(inConfigTOML: toml)[Self.key] == "sha256:old")
  }

  /// Mixed endings are worse than uniform ones: only the header line needs to
  /// end in CRLF. The header and its `trusted_hash` become one `Character`-level
  /// line, so the scanner records the table but never sees its hash, and then
  /// *inserts* a second `trusted_hash` into a table that already has one.
  ///
  /// Real parser verdict on today's output: `Cannot overwrite a value`.
  @Test("a CRLF header line does not get a second trusted_hash inserted under it")
  func crlfHeaderDoesNotDuplicateTheHash() throws {
    let toml =
      "model = \"o3\"\n\n\(Self.header(Self.key))\r\ntrusted_hash = \"sha256:old\"\n"
    let out = try CodexTrustWriter.apply(Self.records(), to: toml)
    #expect(Self.count("trusted_hash", in: out) == 1)
  }

  /// A UTF-8 BOM. Rust's TOML parser strips one explicitly
  /// (`toml_parser/src/lexer/mod.rs`), so Codex reads this file fine, but
  /// `CharacterSet.whitespaces` does not contain U+FEFF — so the first line
  /// does not look like a table header to us and we append a duplicate.
  @Test("a leading BOM does not hide the first table")
  func bomDoesNotDuplicateTheTable() throws {
    let toml = "\u{FEFF}\(Self.header(Self.key))\ntrusted_hash = \"sha256:old\"\n"
    let out = try CodexTrustWriter.apply(Self.records(), to: toml)
    #expect(Self.count(Self.header(Self.key), in: out) == 1)
  }

  // MARK: - Values that span lines

  /// Any line beginning with `[` inside a multi-line string clears the
  /// scanner's idea of which table it is in, so the real `trusted_hash`
  /// below it is never recorded and a second one is inserted under the header.
  ///
  /// Real parser verdict on today's output: `Cannot overwrite a value`.
  @Test("a bracket inside a multi-line string does not duplicate trusted_hash")
  func multilineStringDoesNotDuplicateTheHash() throws {
    let toml = """
      \(Self.header(Self.key))
      note = \"\"\"
      [reminder] I checked this command myself
      \"\"\"
      trusted_hash = "sha256:old"
      """
    let out = try CodexTrustWriter.apply(Self.records(), to: toml)
    #expect(Self.count("trusted_hash", in: out) == 1)
  }

  /// The same hole reached through a nested array rather than a string.
  @Test("a nested array does not duplicate trusted_hash")
  func nestedArrayDoesNotDuplicateTheHash() throws {
    let toml = """
      \(Self.header(Self.key))
      tags = [
        [1, 2],
      ]
      trusted_hash = "sha256:old"
      """
    let out = try CodexTrustWriter.apply(Self.records(), to: toml)
    #expect(Self.count("trusted_hash", in: out) == 1)
  }

  /// A multi-line string that merely *quotes* a trust record — a note someone
  /// pasted — is mistaken for the record itself. The writer reports success
  /// having edited the inside of a string literal, leaving the real record
  /// untouched and the user's note silently rewritten.
  ///
  /// Asserted against the text rather than against
  /// `CodexHookTrust.trustRecords`, deliberately. The reader shares the
  /// writer's blind spot, so it reports this file as correctly trusted and a
  /// round-trip through it cannot see the bug — which is exactly why the
  /// existing `roundTrips` test passes. Measuring the output with the same
  /// broken ruler that produced it proves nothing.
  @Test("a trust record quoted inside a string is not mistaken for the real one")
  func quotedRecordIsNotMistakenForTheRealOne() throws {
    let toml = """
      \(Self.header(Self.key))
      trusted_hash = "sha256:old"

      [notes]
      text = \"\"\"
      \(Self.header(Self.key))
      \"\"\"
      """
    let out = try CodexTrustWriter.apply(Self.records(), to: toml)
    // The real record still says `sha256:old`; only the note was rewritten.
    #expect(!out.contains("sha256:old"))
  }

  // MARK: - Keys the writer emits but cannot read back

  /// A `]` anywhere in the path — a directory called `we]ird` is legal on
  /// macOS — makes `apply` non-idempotent: it writes a table it cannot then
  /// find, so a second press appends the same table again and the file stops
  /// parsing. This one is self-inflicted; no other tool has to be involved.
  @Test("a key containing ] survives a second press")
  func keyWithBracketIsIdempotent() throws {
    let key = "/Users/aniket/we]ird/.codex/hooks.json:stop:0:0"
    let once = try CodexTrustWriter.apply(Self.records(key: key), to: "model = \"o3\"\n")
    let twice = try CodexTrustWriter.apply(Self.records(key: key), to: once)
    #expect(once == twice)
  }

  /// A newline in the path is also legal on macOS, and `quotedKey` passes it
  /// through raw. A TOML basic string may not contain a literal newline, so
  /// the whole file stops parsing on the line we just wrote.
  @Test("a key containing a newline is not written raw into a basic string")
  func keyWithNewlineIsEscaped() throws {
    let key = "/Users/aniket/we\nird/.codex/hooks.json:stop:0:0"
    let out = try CodexTrustWriter.apply(Self.records(key: key), to: "model = \"o3\"\n")
    #expect(!out.contains("\"/Users/aniket/we\nird/"))
  }

  // MARK: - Records written in a shape we do not read

  /// A record expressed as a top-level dotted key. TOML forbids redefining
  /// with a `[table]` header something a dotted key already defined, so
  /// appending produces a file Codex cannot parse. Refusing is an acceptable
  /// answer here; duplicating is not.
  @Test("a top-level dotted record is not duplicated")
  func topLevelDottedRecordIsNotDuplicated() throws {
    let toml = "hooks.state.\"\(Self.key)\".trusted_hash = \"sha256:old\"\n"
    do {
      let out = try CodexTrustWriter.apply(Self.records(), to: toml)
      #expect(Self.count(Self.header(Self.key), in: out) == 0)
    } catch is CodexTrustWriter.Refusal {
      // Declining to touch a shape we do not write is a correct outcome.
    }
  }

  /// `[hooks.state]` carrying a dotted `enabled` — a user who turned one hook
  /// off by hand. That dotted key defines `hooks.state."…"` as a table, so our
  /// appended header redefines it and the file stops parsing. The writer's
  /// existing refusal only covers a dotted `trusted_hash`, not a dotted
  /// anything-else under the same key.
  @Test("a dotted enabled under [hooks.state] is not duplicated")
  func dottedEnabledIsNotDuplicated() throws {
    let toml = "[hooks.state]\n\"\(Self.key)\".enabled = true\n"
    do {
      let out = try CodexTrustWriter.apply(Self.records(), to: toml)
      #expect(Self.count(Self.header(Self.key), in: out) == 0)
    } catch is CodexTrustWriter.Refusal {
      // Declining is a correct outcome.
    }
  }

  // MARK: - The hashed identity

  /// Codex clamps `SessionEnd` and `Interrupt` timeouts to three seconds
  /// *before* hashing — `normalize_command_hook` in
  /// `codex-rs/hooks/src/engine/discovery.rs` ends
  /// `.clamp(1, SESSION_END_MAX_TIMEOUT_SEC)`, and that constant is 3.
  /// `CodexHookTrust.entries` applies only `max(1, timeout)`, so any
  /// `SessionEnd` or `Interrupt` hook of ours carrying an explicit timeout
  /// above three hashes differently from the way Codex hashes it.
  ///
  /// The visible harm is a false accusation: a hook Codex itself trusts is
  /// reported as `modified`, and pressing the button writes a hash Codex will
  /// never accept.
  @Test("a SessionEnd timeout above three seconds hashes the way Codex hashes it")
  func sessionEndTimeoutIsClamped() throws {
    let script = "/Users/aniket/.vigil/hooks/vigil-hook.sh"
    let command = "'\(script)' codex SessionEnd idle"
    let json = """
      {"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"\(command)","timeout":30}]}]}}
      """
    let settings =
      (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]

    // What Codex computes: the timeout clamped to three seconds.
    let codexHash = CodexHookTrust.identityHash(
      event: "SessionEnd", command: command, timeoutSeconds: 3)

    let ours = CodexTrustWriter.records(
      hooks: settings, hooksPath: Self.hooksPath, scriptPath: script, integration: .codex)
    #expect(ours?.first?.hash == codexHash)

    // …and so a config Codex already trusts must not read as `modified`.
    let trusted =
      "\(Self.header("\(Self.hooksPath):session_end:0:0"))\n"
      + "trusted_hash = \"\(codexHash ?? "")\"\n"
    #expect(
      CodexHookTrust.status(
        hooks: settings, hooksPath: Self.hooksPath, configTOML: trusted,
        scriptPath: script, integration: .codex) == .trusted)
  }
}
