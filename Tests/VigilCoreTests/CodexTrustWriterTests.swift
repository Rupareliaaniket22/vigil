import Foundation
import Testing

@testable import VigilCore

private let script = "/Users/aniket/.vigil/hooks/vigil-hook.sh"
private let hooksPath = "/Users/aniket/.codex/hooks.json"

private func parse(_ json: String) -> [String: Any] {
  (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

private func writerRecords() -> [CodexTrustWriter.Record] {
  CodexTrustWriter.records(
    hooks: parse(hooksJSON), hooksPath: hooksPath, scriptPath: script, integration: .codex) ?? []
}

@Suite("Recording a trust decision in Codex's config")
struct CodexTrustWriterTests {

  /// The test that matters. Everything else here guards a way of getting this
  /// wrong; this one says the feature works at all, and it says so by asking
  /// the *reader* — the code that established the problem in the first place —
  /// rather than by inspecting the text we just wrote.
  @Test("what we write is what Codex would have written")
  func roundTrips() throws {
    let settings = parse(hooksJSON)
    let before = CodexHookTrust.status(
      hooks: settings, hooksPath: hooksPath, configTOML: configWithOtherToolsRecords,
      scriptPath: script, integration: .codex)
    #expect(before != .trusted, "the fixture has to start untrusted or this proves nothing")

    let after = try CodexTrustWriter.apply(writerRecords(), to: configWithOtherToolsRecords)

    #expect(
      CodexHookTrust.status(
        hooks: settings, hooksPath: hooksPath, configTOML: after,
        scriptPath: script, integration: .codex) == .trusted)
  }

  @Test("pressing it twice is the same as pressing it once")
  func idempotent() throws {
    let once = try CodexTrustWriter.apply(writerRecords(), to: configWithOtherToolsRecords)
    let twice = try CodexTrustWriter.apply(writerRecords(), to: once)
    #expect(once == twice)
  }

  /// Vigil is editing a file full of settings it knows nothing about.
  @Test("every other line survives byte for byte")
  func preservesEverythingElse() throws {
    let original = """
      # A comment someone wrote
      model = "o3"
      approval_policy = "on-request"

      [some.other.table]
      value = 42

      \(configWithOtherToolsRecords)
      """
    let after = try CodexTrustWriter.apply(writerRecords(), to: original)
    // Blank lines are skipped because Foundation's `range(of:)` finds no match
    // for an empty string, so `contains("")` is false and would fail here
    // whatever the writer did. Their placement is covered by the file still
    // parsing back correctly in the other tests.
    for line in original.split(separator: "\n") where !line.isEmpty {
      #expect(after.contains(line), "lost: \(line)")
    }
    #expect(after.hasPrefix(original), "existing content should be untouched and come first")
  }

  /// The other tool's approvals are not ours to touch.
  @Test("another tool's records are left alone")
  func leavesOtherRecordsAlone() throws {
    let after = try CodexTrustWriter.apply(writerRecords(), to: configWithOtherToolsRecords)
    let records = CodexHookTrust.trustRecords(inConfigTOML: after)
    #expect(
      records["/Users/aniket/.codex/hooks.json:stop:0:0"]
        == "sha256:38367b0bb5bfdadd9515dc4c7c6fed3e28a0ef911f3d6b65e60f89b512471f86")
  }

  /// A hook that was trusted and has since changed: Codex calls this
  /// `modified`. The record has to be replaced, never added beside the old one.
  @Test("a stale record is replaced, not duplicated")
  func replacesStaleRecord() throws {
    let records = writerRecords()
    let stale = try #require(records.first)
    let config = """
      [hooks.state.\(#""\#(stale.key)""#)]
      trusted_hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
      """
    let after = try CodexTrustWriter.apply(records, to: config)

    let header = "[hooks.state.\(#""\#(stale.key)""#)]"
    let occurrences = after.components(separatedBy: header).count - 1
    #expect(occurrences == 1, "TOML rejects a file that defines the same key twice")
    #expect(CodexHookTrust.trustRecords(inConfigTOML: after)[stale.key] == stale.hash)
  }

  @Test("a config with no records at all gets them all")
  func writesIntoAnEmptyConfig() throws {
    let records = writerRecords()
    let after = try CodexTrustWriter.apply(records, to: "model = \"o3\"\n")
    let written = CodexHookTrust.trustRecords(inConfigTOML: after)
    #expect(written.count == records.count)
    #expect(after.hasPrefix("model = \"o3\""))
  }

  /// A file not ending in a newline must not get our table header welded onto
  /// its last setting.
  @Test("a file with no trailing newline is still valid after")
  func handlesMissingTrailingNewline() throws {
    let after = try CodexTrustWriter.apply(writerRecords(), to: "model = \"o3\"")
    #expect(after.contains("model = \"o3\"\n"))
    #expect(!after.contains("model = \"o3\"[hooks"))
  }

  /// The refusals. Both of these shapes are legal TOML that Codex reads and
  /// this writer does not produce; appending our own definition beside one
  /// would define the same key twice, which makes the file unparseable and
  /// stops Codex running *every* tool's hooks.
  @Test("refuses a dotted key rather than duplicate it")
  func refusesDottedKey() {
    let records = writerRecords()
    let key = records.first!.key
    let config = """
      [hooks.state]
      "\(key)".trusted_hash = "sha256:00"
      """
    #expect(throws: CodexTrustWriter.Refusal.unfamiliarRecord(key: key)) {
      try CodexTrustWriter.apply(records, to: config)
    }
  }

  @Test("refuses an inline table rather than duplicate it")
  func refusesInlineTable() {
    let records = writerRecords()
    let key = records.first!.key
    let config = """
      [hooks.state]
      "\(key)" = { trusted_hash = "sha256:00" }
      """
    #expect(throws: CodexTrustWriter.Refusal.unfamiliarRecord(key: key)) {
      try CodexTrustWriter.apply(records, to: config)
    }
  }

  @Test("writes nothing when it cannot identify every hook")
  func refusesEmptyRecords() {
    #expect(throws: CodexTrustWriter.Refusal.cannotIdentifyHooks) {
      try CodexTrustWriter.apply([], to: "")
    }
  }

  /// Only Codex gates hooks, and asking for records for a host with no gate
  /// should produce none rather than a plausible-looking list.
  @Test("a host with no trust gate yields no records")
  func noRecordsForUngatedHosts() {
    for integration in AgentIntegration.all where !integration.requiresHookTrust {
      #expect(
        CodexTrustWriter.records(
          hooks: parse(hooksJSON), hooksPath: hooksPath, scriptPath: script,
          integration: integration) == nil)
    }
  }

  /// A file saved with CRLF, which is how one arrives from a synced Windows
  /// machine or an editor set that way. Codex reads it perfectly well, so the
  /// only thing that can go wrong here is Vigil: either failing to see the
  /// records in it, or handing the user back a file whose every line ending
  /// has been changed on their behalf.
  @Test("a CRLF file keeps every one of its line endings")
  func preservesCRLF() throws {
    let records = writerRecords()
    let original = "# a note\r\nmodel = \"o3\"\r\n\r\n[tui]\r\nvalue = 1\r\n"
    let after = try CodexTrustWriter.apply(records, to: original)

    #expect(after.hasPrefix(original), "the file we were given comes back unchanged and first")
    #expect(!after.contains("\n\n"), "no line may be left with a bare LF")
    #expect(
      after.components(separatedBy: "\r\n").count - 1 == after.components(separatedBy: "\n").count
        - 1,
      "every newline in the result is part of a CRLF pair")
    #expect(
      CodexHookTrust.trustRecords(inConfigTOML: after).count == records.count,
      "and the reader can see what was written")
  }

  /// The same file twice over, which is what a second press is. Asserted on a
  /// CRLF file because that is where it used to fail: nothing split, so nothing
  /// was found, so the same tables were appended again.
  @Test("pressing it twice on a CRLF file is the same as pressing it once")
  func idempotentOverCRLF() throws {
    let records = writerRecords()
    let once = try CodexTrustWriter.apply(records, to: "model = \"o3\"\r\n")
    let twice = try CodexTrustWriter.apply(records, to: once)
    #expect(once == twice)
  }

  /// Another tool writing its own records in a shape Vigil does not produce is
  /// none of Vigil's business, and must not stop Vigil writing its own. TOML is
  /// perfectly happy to see `[hooks.state."ours"]` after a `[hooks.state]` full
  /// of somebody else's dotted keys; refusing here would be a refusal the user
  /// could do nothing about and did not deserve.
  @Test("another tool's dotted record does not block ours")
  func otherToolsDottedRecordIsNotOurProblem() throws {
    let records = writerRecords()
    let config = """
      [hooks.state]
      "/opt/other/hooks.json:stop:0:0".trusted_hash = "sha256:theirs"
      """
    let after = try CodexTrustWriter.apply(records, to: config)
    let written = CodexHookTrust.trustRecords(inConfigTOML: after)
    #expect(written["/opt/other/hooks.json:stop:0:0"] == "sha256:theirs")
    for record in records { #expect(written[record.key] == record.hash) }
  }

  /// A `trusted_hash` written across several lines is still one statement, and
  /// replacing only its first line would leave the rest of it behind as
  /// nonsense the file could not parse.
  @Test("a trusted_hash spanning lines is replaced whole")
  func replacesAMultiLineStatement() throws {
    let records = writerRecords()
    let stale = try #require(records.first)
    let config = """
      [hooks.state.\(#""\#(stale.key)""#)]
      trusted_hash = \"\"\"
      sha256:0000
      \"\"\"
      """
    let after = try CodexTrustWriter.apply(records, to: config)
    #expect(!after.contains("sha256:0000"))
    #expect(!after.contains("\"\"\""), "no half of the old statement is left behind")
    #expect(CodexHookTrust.trustRecords(inConfigTOML: after)[stale.key] == stale.hash)
  }

  /// The refusal for a file rather than for a record. Nothing here names a key
  /// — the value never ends, so the scanner cannot say what is in the rest of
  /// the file, and a second definition of our key is exactly the sort of thing
  /// that would be hiding there.
  @Test("refuses a config it cannot scan to the end")
  func refusesAnUnscannableConfig() {
    let records = writerRecords()
    #expect(throws: CodexTrustWriter.Refusal.unfamiliarConfig) {
      try CodexTrustWriter.apply(records, to: "note = \"\"\"\nstill going\n")
    }
    // `hooks` as an inline table: closed for good, so no header may extend it.
    #expect(throws: CodexTrustWriter.Refusal.unfamiliarConfig) {
      try CodexTrustWriter.apply(records, to: "hooks = { state = {} }\n")
    }
    // And an array of tables, which a table header cannot be added to either.
    #expect(throws: CodexTrustWriter.Refusal.unfamiliarConfig) {
      try CodexTrustWriter.apply(records, to: "[[hooks.state]]\ntrusted_hash = \"x\"\n")
    }
  }

  /// A record Codex can read and Vigil writes in a different shape is the one
  /// case where appending is fatal, and it is reached by more routes than the
  /// dotted key under `[hooks.state]` the writer used to know about.
  @Test(
    "every shape that would define our key twice is refused",
    arguments: [
      "hooks.state.%KEY%.trusted_hash = \"sha256:00\"",
      "[hooks]\nstate.%KEY%.trusted_hash = \"sha256:00\"",
      "[hooks.state]\n%KEY%.enabled = true",
      "[hooks.state.%KEY%.extra]\nvalue = 1",
      "[hooks.state.%KEY%]\ntrusted_hash = \"a\"\n\n[hooks.state.%KEY%]\ntrusted_hash = \"b\"",
    ])
  func refusesEveryDuplicatingShape(template: String) throws {
    let records = writerRecords()
    let key = try #require(records.first).key
    let config = template.replacingOccurrences(of: "%KEY%", with: "\"\(key)\"")
    #expect(throws: CodexTrustWriter.Refusal.unfamiliarRecord(key: key)) {
      try CodexTrustWriter.apply(records, to: config)
    }
  }

  /// A comment, a tab and a byte-order mark are all things a real file has and
  /// Codex reads. None of them may hide a table we would then write again.
  @Test("a table is found through a BOM, a tab and a trailing comment")
  func findsATableThroughOrdinaryNoise() throws {
    let records = writerRecords()
    let stale = try #require(records.first)
    let config =
      "\u{FEFF}\t[hooks.state.\(#""\#(stale.key)""#)]  # approved by hand\n"
      + "\ttrusted_hash = \"sha256:0000\"\n"
    let after = try CodexTrustWriter.apply(records, to: config)
    let header = "[hooks.state.\(#""\#(stale.key)""#)]"
    #expect(after.components(separatedBy: header).count - 1 == 1)
    #expect(after.contains("# approved by hand"), "their comment is theirs")
    #expect(CodexHookTrust.trustRecords(inConfigTOML: after)[stale.key] == stale.hash)
  }

  /// A path can legally contain a quote, and an unescaped one would end the key
  /// early — silently filing the approval against a different entry.
  @Test("a key containing a quote is escaped")
  func escapesQuotesInKeys() throws {
    let record = CodexTrustWriter.Record(
      key: #"/Users/a"b/.codex/hooks.json:stop:0:0"#, hash: "sha256:ab", event: "Stop")
    let after = try CodexTrustWriter.apply([record], to: "")
    #expect(after.contains(#"[hooks.state."/Users/a\"b/.codex/hooks.json:stop:0:0"]"#))
    #expect(CodexHookTrust.trustRecords(inConfigTOML: after)[record.key] == "sha256:ab")
  }
}

/// The shape a real machine has: another tool already occupies matcher index 0
/// for the events it cares about, so Vigil's entry lands at index 1 — which is
/// the whole reason the position-keyed trust record went wrong in the first
/// place. `SessionEnd` and `Interrupt` are Vigil's alone, at index 0.
///
/// Deliberately not the simpler "Vigil at 0:0 everywhere": that fixture cannot
/// tell a writer that respects another tool's records from one that overwrites
/// them, because both tools would share every key.
private let hooksJSON = """
  {
    "hooks": {
      "SessionStart": [
        {"hooks": [{"type": "command", "command": "/opt/other/hook.sh start"}]},
        {"hooks": [{"type": "command", "command": "\(script) codex SessionStart"}]}
      ],
      "Stop": [
        {"hooks": [{"type": "command", "command": "/opt/other/hook.sh stop"}]},
        {"hooks": [{"type": "command", "command": "\(script) codex Stop"}]}
      ],
      "SessionEnd": [{"hooks": [{"type": "command", "command": "\(script) codex SessionEnd"}]}],
      "Interrupt": [{"hooks": [{"type": "command", "command": "\(script) codex Interrupt"}]}]
    }
  }
  """

/// A real `config.toml`: five approvals, none of them for Vigil.
private let configWithOtherToolsRecords = """
  [hooks.state."/Users/aniket/.codex/hooks.json:post_tool_use:0:0"]
  trusted_hash = "sha256:2e0a4c29ce3b8e43df9aa43d774abb37a2e48877398bd98e7042f318e0a54ca8"

  [hooks.state."/Users/aniket/.codex/hooks.json:stop:0:0"]
  trusted_hash = "sha256:38367b0bb5bfdadd9515dc4c7c6fed3e28a0ef911f3d6b65e60f89b512471f86"
  """
