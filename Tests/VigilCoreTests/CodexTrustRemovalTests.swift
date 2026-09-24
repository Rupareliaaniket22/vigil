import Foundation
import Testing

@testable import VigilCore

private let script = "/Users/aniket/.vigil/hooks/vigil-hook.sh"
private let hooksPath = "/Users/aniket/.codex/hooks.json"

private func parse(_ json: String) -> [String: Any] {
  (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

private func ourRecords() -> [CodexTrustWriter.Record] {
  CodexTrustWriter.records(
    hooks: parse(hooksJSON), hooksPath: hooksPath, scriptPath: script, integration: .codex) ?? []
}

private func trustState(of toml: String) -> HookTrustState {
  CodexHookTrust.status(
    hooks: parse(hooksJSON), hooksPath: hooksPath, configTOML: toml,
    scriptPath: script, integration: .codex)
}

/// Taking an approval back out of Codex's config.
///
/// The defect these describe is not a security hole, and saying so first keeps
/// the tests honest about what they are for. Removing Vigil's hooks took the
/// entries out of `hooks.json` and deleted the shared script, and left every
/// `[hooks.state."…"]` table behind. The source called those inert orphaned
/// keys. They are not inert: the key names the hooks file, the event, the group
/// and the handler, and the hash covers the entry — so putting the same entries
/// back produces the same keys and the same hashes, and the host is satisfied
/// by a decision nobody is asked to make a second time. Verified on a real
/// machine: after a removal and a relaunch the hooks installed, no trust write
/// happened, and the state read back `trusted`.
///
/// Exploiting that needs write access to `hooks.json` — which is write access
/// to a file that would let you edit `config.toml` directly anyway. The defect
/// worth fixing is the plain one: the button says Undo and it did not undo.
///
/// Every assertion below is made with Vigil's own reader, which is the right
/// primary check — a reader and a writer that disagreed is what caused most of
/// the bugs in the sibling suite. But those two share a scanner and therefore
/// share its blind spots, and the failure that costs the user most is not
/// "Vigil misread it", it is "Codex cannot parse it at all". So every file this
/// suite produces also goes through a real TOML parser; see `parsesAsTOML`.
@Suite("Taking a trust decision back out of Codex's config")
struct CodexTrustRemovalTests {

  // MARK: - It actually removes

  /// The test that matters, and it is the one the old code could not pass.
  @Test("what Vigil wrote is what Vigil takes away")
  func removesWhatItWrote() throws {
    let records = ourRecords()
    let approved = try CodexTrustWriter.apply(records, to: configWithOtherToolsRecords)
    #expect(trustState(of: approved) == .trusted, "the fixture has to be trusted first")

    let after = try CodexTrustWriter.remove(records, from: approved)
    #expect(trustState(of: after) != .trusted)
    for record in records {
      #expect(
        CodexHookTrust.trustRecords(inConfigTOML: after)[record.key] == nil,
        "left behind: \(record.key)")
    }
  }

  /// The whole point of removing them: a later install must not be silently
  /// pre-approved by a decision the user thought they had reversed.
  @Test("re-installing after a removal is untrusted again")
  func reinstallingIsNotPreApproved() throws {
    let records = ourRecords()
    let approved = try CodexTrustWriter.apply(records, to: configWithOtherToolsRecords)
    let removed = try CodexTrustWriter.remove(records, from: approved)
    // Nothing changes in `hooks.json` between these two lines — the entries
    // going away and coming back produce the same keys and the same hashes,
    // which is exactly why leaving the records behind re-armed them.
    #expect(trustState(of: removed) != .trusted)
  }

  @Test("removing twice is the same as removing once")
  func idempotent() throws {
    let records = ourRecords()
    let approved = try CodexTrustWriter.apply(records, to: configWithOtherToolsRecords)
    let once = try CodexTrustWriter.remove(records, from: approved)
    let twice = try CodexTrustWriter.remove(records, from: once)
    #expect(once == twice)
  }

  /// Install, undo, install, undo. The writer separates tables it appends with
  /// a blank line, so this had to be shown to settle rather than to grow one
  /// per cycle — and it did not, the first time it was asked. The remover now
  /// takes a blank line only when the statement above it is going too, which
  /// leaves the one between the user's own settings and the first of our
  /// tables and takes the ones between ours.
  @Test("a second install-and-undo produces the same file as the first")
  func cyclesAreStable() throws {
    let records = ourRecords()
    let firstOn = try CodexTrustWriter.apply(records, to: configWithOtherToolsRecords)
    let firstOff = try CodexTrustWriter.remove(records, from: firstOn)
    let secondOn = try CodexTrustWriter.apply(records, to: firstOff)
    let secondOff = try CodexTrustWriter.remove(records, from: secondOn)
    #expect(secondOn == firstOn)
    #expect(secondOff == firstOff)
  }

  // MARK: - It removes nothing else

  /// Vigil is editing a file full of settings it knows nothing about, and on
  /// the way out just as much as on the way in.
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
    let records = ourRecords()
    let after = try CodexTrustWriter.remove(
      records, from: try CodexTrustWriter.apply(records, to: original))
    for line in original.split(separator: "\n") where !line.isEmpty {
      #expect(after.contains(line), "lost: \(line)")
    }
    #expect(after.hasPrefix(original), "existing content should be untouched and come first")
  }

  @Test("another tool's records are left alone")
  func leavesOtherRecordsAlone() throws {
    let records = ourRecords()
    let after = try CodexTrustWriter.remove(
      records, from: try CodexTrustWriter.apply(records, to: configWithOtherToolsRecords))
    let remaining = CodexHookTrust.trustRecords(inConfigTOML: after)
    #expect(
      remaining["/Users/aniket/.codex/hooks.json:stop:0:0"]
        == "sha256:38367b0bb5bfdadd9515dc4c7c6fed3e28a0ef911f3d6b65e60f89b512471f86")
    #expect(remaining.count == 2, "both of theirs, neither of ours")
  }

  /// A key of ours holding a hash we did not write belongs to whoever wrote it.
  /// The same answer `selfWrittenRecords` gives on the way in.
  @Test("a record whose hash is not the one being removed stays")
  func leavesAHashItDidNotWrite() throws {
    let record = try #require(ourRecords().first)
    let config = """
      [hooks.state."\(record.key)"]
      trusted_hash = "sha256:somebodyelseswork"
      """
    let after = try CodexTrustWriter.remove([record], from: config)
    #expect(after == config)
  }

  /// The header is what keeps anything else in the table reachable, so it only
  /// goes when the table is nothing but our record.
  @Test("a table holding another setting keeps its header")
  func keepsAHeaderThatIsStillHoldingSomethingUp() throws {
    let record = try #require(ourRecords().first)
    let config = """
      [hooks.state."\(record.key)"]
      trusted_hash = "\(record.hash)"
      someone_elses_flag = true
      """
    let after = try CodexTrustWriter.remove([record], from: config)
    #expect(after.contains(#"[hooks.state."\#(record.key)"]"#))
    #expect(after.contains("someone_elses_flag = true"))
    #expect(!after.contains(record.hash))
  }

  @Test("a key that is not in the file is not an error")
  func absentKeyIsFine() throws {
    let after = try CodexTrustWriter.remove(ourRecords(), from: configWithOtherToolsRecords)
    #expect(after == configWithOtherToolsRecords)
  }

  /// Unlike `apply`, where an empty list means the entries could not be
  /// identified and approving none of them would be a half-fix reported as a
  /// success. Nothing asked for is nothing removed.
  @Test("an empty list changes nothing and does not throw")
  func emptyListIsANoOp() throws {
    #expect(
      try CodexTrustWriter.remove([], from: configWithOtherToolsRecords)
        == configWithOtherToolsRecords)
  }

  /// A file saved with CRLF stays a CRLF file. The scanner cuts on the newline
  /// scalar for exactly this reason, and a remover that rebuilt lines from
  /// `split` would normalise the whole file on the way past.
  @Test("a CRLF file keeps its line endings")
  func preservesCRLF() throws {
    let record = try #require(ourRecords().first)
    let config =
      "model = \"o3\"\r\n[hooks.state.\"\(record.key)\"]\r\ntrusted_hash = "
      + "\"\(record.hash)\"\r\n"
    let after = try CodexTrustWriter.remove([record], from: config)
    #expect(after == "model = \"o3\"\r\n")
  }

  // MARK: - It refuses what it cannot read

  /// The same standard as the writer: a record in a shape Vigil does not
  /// produce is one Vigil will not edit, in either direction.
  @Test("a dotted record is refused rather than guessed at")
  func refusesADottedRecord() throws {
    let record = try #require(ourRecords().first)
    let config = """
      [hooks.state]
      "\(record.key)" = { trusted_hash = "\(record.hash)" }
      """
    #expect(throws: CodexTrustWriter.Refusal.unfamiliarRecord(key: record.key)) {
      try CodexTrustWriter.remove([record], from: config)
    }
  }

  /// A file nothing can be located in with confidence has no safe edit in it,
  /// and "delete these lines" is the edit where guessing costs the most.
  @Test("a config that cannot be read with confidence is refused")
  func refusesAnUnreadableConfig() throws {
    let record = try #require(ourRecords().first)
    let config = """
      hooks = { state = { } }
      [hooks.state."\(record.key)"]
      trusted_hash = "\(record.hash)"
      """
    #expect(throws: CodexTrustWriter.Refusal.unfamiliarConfig) {
      try CodexTrustWriter.remove([record], from: config)
    }
  }

  /// Two tables of the same name is already a file TOML rejects. Deleting the
  /// one we happened to stop on would leave the other still approving.
  @Test("a key defined twice is refused")
  func refusesADoubledTable() throws {
    let record = try #require(ourRecords().first)
    let config = """
      [hooks.state."\(record.key)"]
      trusted_hash = "\(record.hash)"

      [hooks.state."\(record.key)"]
      trusted_hash = "\(record.hash)"
      """
    #expect(throws: CodexTrustWriter.Refusal.unfamiliarRecord(key: record.key)) {
      try CodexTrustWriter.remove([record], from: config)
    }
  }

  // MARK: - Somebody else's parser

  /// Every file this suite produces, read by a TOML parser that has never
  /// heard of Vigil.
  ///
  /// One test and one subprocess rather than a check inside each case: `make
  /// test` is the sub-second loop people run constantly, and a dozen python
  /// launches is not a thing to put in it.
  ///
  /// Reported as skipped, not as passed, where there is no parser to ask.
  /// `tomllib` arrived in Python 3.11 and the Command Line Tools ship 3.9, so
  /// on a stock machine this cannot run — which is a fact about the machine
  /// and should look like one.
  @Test("every file this suite writes still parses as TOML", .enabled(if: PythonTOML.isAvailable))
  func parsesAsTOML() throws {
    let records = ourRecords()
    let stale = try #require(records.first)

    var produced: [String: String] = [:]
    let withOthers = try CodexTrustWriter.apply(records, to: configWithOtherToolsRecords)
    produced["approved"] = withOthers
    produced["removed"] = try CodexTrustWriter.remove(records, from: withOthers)

    let crlf =
      "model = \"o3\"\r\n[hooks.state.\"\(stale.key)\"]\r\ntrusted_hash = "
      + "\"\(stale.hash)\"\r\n"
    produced["crlf"] = try CodexTrustWriter.remove([stale], from: crlf)

    let withNeighbour = """
      [hooks.state."\(stale.key)"]
      trusted_hash = "\(stale.hash)"
      someone_elses_flag = true

      [profiles.work]
      model = "o3"
      """
    produced["header kept"] = try CodexTrustWriter.remove([stale], from: withNeighbour)

    let fullFile = """
      # A comment someone wrote
      model = "o3"

      [some.other.table]
      value = 42

      \(configWithOtherToolsRecords)
      """
    produced["whole file"] = try CodexTrustWriter.remove(
      records, from: try CodexTrustWriter.apply(records, to: fullFile))

    // Twice through the cycle, which is where a remover that ate a blank line
    // it did not write would show up as a file running two tables together.
    var cycled = fullFile
    for _ in 0..<2 {
      cycled = try CodexTrustWriter.apply(records, to: cycled)
      cycled = try CodexTrustWriter.remove(records, from: cycled)
    }
    produced["two cycles"] = cycled

    for failure in try PythonTOML.failures(in: produced) {
      Issue.record("\(failure)")
    }
  }
}

/// A real TOML parser, borrowed from Python, for checking what Vigil wrote.
enum PythonTOML {

  /// A `python3` on this machine whose `tomllib` imports, or none.
  ///
  /// Resolved once. The check is the import rather than a version string,
  /// because the version string is a proxy for it and the import is the thing.
  static let interpreter: String? = {
    for candidate in ["/usr/bin/env"] {
      guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
      if run(candidate, ["python3", "-c", "import tomllib"]) == 0 { return candidate }
    }
    return nil
  }()

  static var isAvailable: Bool { interpreter != nil }

  /// The files that would not parse, named, with the parser's own complaint.
  ///
  /// Written to disk and read back as bytes on the far side rather than passed
  /// as text: Python's text mode translates CRLF to LF on the way in, which
  /// would hide the one class of damage a line-removing writer is most likely
  /// to do.
  static func failures(in files: [String: String]) throws -> [String] {
    guard let interpreter else { return [] }

    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("vigil-toml-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let labels = Array(files.keys).sorted()
    for (index, label) in labels.enumerated() {
      try Data(files[label]!.utf8).write(
        to: directory.appendingPathComponent("\(index).toml"))
    }

    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: interpreter)
    process.arguments = ["python3", "-c", checker, directory.path]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n")
      .compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2, let index = Int(parts[0]), labels.indices.contains(index) else {
          return nil
        }
        return "\(labels[index]): \(parts[1])"
      }
  }

  /// Strips a leading byte-order mark before parsing. TOML does not allow one
  /// and `tomllib` refuses it, but Codex's Rust lexer removes one before
  /// parsing — so a BOM'd file is one Codex reads perfectly well, and failing
  /// it here would be this harness disagreeing with the program being modelled.
  private static let checker = """
    import pathlib, sys, tomllib
    for path in sorted(pathlib.Path(sys.argv[1]).glob("*.toml"), key=lambda p: int(p.stem)):
        text = path.read_bytes().decode("utf-8").lstrip("\\ufeff")
        try:
            tomllib.loads(text)
        except Exception as error:
            print(f"{path.stem}\\t{error}")
    """

  private static func run(_ path: String, _ arguments: [String]) -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    process.waitUntilExit()
    return process.terminationStatus
  }
}

/// The shape a real machine has: another tool already occupies matcher index 0
/// for the events it cares about, so Vigil's entry lands at index 1.
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

/// A real `config.toml`: two approvals, neither of them for Vigil.
private let configWithOtherToolsRecords = """
  [hooks.state."/Users/aniket/.codex/hooks.json:post_tool_use:0:0"]
  trusted_hash = "sha256:2e0a4c29ce3b8e43df9aa43d774abb37a2e48877398bd98e7042f318e0a54ca8"

  [hooks.state."/Users/aniket/.codex/hooks.json:stop:0:0"]
  trusted_hash = "sha256:38367b0bb5bfdadd9515dc4c7c6fed3e28a0ef911f3d6b65e60f89b512471f86"
  """
