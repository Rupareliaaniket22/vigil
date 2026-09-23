import Foundation
import Testing

@testable import VigilCore

private let script = "/Users/aniket/.vigil/hooks/vigil-hook.sh"
private let hooksPath = "/Users/aniket/.codex/hooks.json"

/// A `hooks.json` as `HookInstaller` hands it over — parsed, not text.
private func parse(_ json: String) -> [String: Any] {
  (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

// MARK: - Ground truth

/// Captured from a real machine on 2026-09-23, unedited.
///
/// This is the whole argument for the rest of the file. Everything
/// `CodexHookTrust` does is a claim about how somebody else's program behaves,
/// and the only way to hold that claim honest is to run it against that
/// program's own output. These five records were written by Codex when the
/// user trusted five hooks belonging to a different tool; if `identityHash`
/// reproduces all five from the entries they describe, the hash is right, the
/// key format is right, and the snake_case table is right.
private let realConfigTOML = """
  [hooks.state."/Users/aniket/.codex/hooks.json:post_tool_use:0:0"]
  trusted_hash = "sha256:2e0a4c29ce3b8e43df9aa43d774abb37a2e48877398bd98e7042f318e0a54ca8"

  [hooks.state."/Users/aniket/.codex/hooks.json:pre_tool_use:0:0"]
  trusted_hash = "sha256:6bffa141bd54daac45fe4c80198b02d1eb9b33e1f3dbe1622408d945ea2ff41a"

  [hooks.state."/Users/aniket/.codex/hooks.json:session_start:0:0"]
  trusted_hash = "sha256:6e748fe23a3477516e6a0eca48b1b96ece8264830ba32c5a166ae787e5ebe316"

  [hooks.state."/Users/aniket/.codex/hooks.json:stop:0:0"]
  trusted_hash = "sha256:38367b0bb5bfdadd9515dc4c7c6fed3e28a0ef911f3d6b65e60f89b512471f86"

  [hooks.state."/Users/aniket/.codex/hooks.json:user_prompt_submit:0:0"]
  trusted_hash = "sha256:441576c9d657e1bc1ef9f0a01aaf84e036f5b930c6c3f134182d10651129144a"
  """

/// The five entries those records were written for: another tool's hooks,
/// sitting at matcher index 0 of the five events it registers for.
private let otherToolsHooks = [
  ("PostToolUse", "post_tool_use"),
  ("PreToolUse", "pre_tool_use"),
  ("SessionStart", "session_start"),
  ("Stop", "stop"),
  ("UserPromptSubmit", "user_prompt_submit"),
]

@Suite("Codex hook trust, against a real config.toml")
struct CodexHookTrustGroundTruthTests {

  @Test("the hash reproduces every trust record Codex wrote", arguments: otherToolsHooks)
  func reproducesRealRecords(event: String, label: String) {
    let records = CodexHookTrust.trustRecords(inConfigTOML: realConfigTOML)
    let key = CodexHookTrust.stateKey(hooksPath: hooksPath, event: event, group: 0, handler: 0)
    let recorded = records[try! #require(key)]

    let computed = CodexHookTrust.identityHash(
      event: event,
      command: "/Users/aniket/.holdmylid/hooks/codex-notify-hook.sh \(event)",
      timeoutSeconds: 600
    )

    #expect(computed != nil)
    #expect(
      computed == recorded,
      "Codex's own record for \(label) must fall out of our own hash of the entry it names")
  }

  /// The defect, exactly as it stands on that machine.
  ///
  /// Five trust records, seven entries of Vigil's, and not one of the records
  /// belongs to us: they are keyed on matcher index 0, which is where the other
  /// tool's hooks sit, and Vigil's were appended *after* them at index 1. Vigil
  /// read `hooks.json`, found all seven of its entries present, and reported
  /// Codex as "Reporting" while Codex was running none of them.
  @Test("Vigil's own entries are untrusted even where a record exists for the event")
  func realMachineIsUntrusted() {
    let settings = parse(realHooksJSON)
    let state = CodexHookTrust.status(
      hooks: settings, hooksPath: hooksPath, configTOML: realConfigTOML,
      scriptPath: script, integration: .codex)

    #expect(
      state == .untrusted(events: AgentIntegration.codex.allEvents.sorted()),
      "all seven, not the two the event names alone would suggest")
    #expect(!state.isSatisfied)
    #expect(state.blockedEvents.count == 7)
  }

  /// And the consequence: this must not read as `.ready`.
  @Test("an untrusted install does not report as ready")
  func untrustedIsNotReady() {
    let settings = parse(realHooksJSON)
    let missing = HookConfiguration.missingEvents(
      in: settings, scriptPath: script, integration: .codex)
    let trust = CodexHookTrust.status(
      hooks: settings, hooksPath: hooksPath, configTOML: realConfigTOML,
      scriptPath: script, integration: .codex)

    #expect(missing.isEmpty, "every hook we want is in the file — that was never the problem")
    // `.untrusted` rather than merely "not `.ready`": the panel offers a
    // different action for each, and re-running the install — which is what
    // `.outOfDate` offers — is precisely the thing that does not fix this.
    #expect(
      HookConfiguration.setupState(
        missingEvents: missing, expectedEvents: AgentIntegration.codex.allEvents, trust: trust)
        == .untrusted)
  }
}

// MARK: - The hash

@Suite("Codex's hook identity hash")
struct CodexIdentityHashTests {

  /// Expected values computed independently, outside Swift, from Codex's
  /// published recipe. A second implementation agreeing is worth more here than
  /// any number of assertions about our own output.
  @Test(
    "known hashes",
    arguments: [
      (
        "PostToolUse", "'\(script)' codex PostToolUse working", 600,
        "sha256:67618a1f392c80462f329791949673d040092534ff9cddb53070c77a07b580e6"
      ),
      (
        "Stop", "'\(script)' codex Stop idle", 600,
        "sha256:1b44076151442c9a07ed5c68ea8119f6f4c10df4b3259486d21ef3efe02bcf40"
      ),
      (
        "SessionEnd", "'\(script)' codex SessionEnd idle", 1,
        "sha256:688da2022aeaa82942806e265df589e759d7345183e5e1bfc1e2c8c58671adec"
      ),
      (
        "Interrupt", "'\(script)' codex Interrupt idle", 1,
        "sha256:6a6af673264741b4df3e8ac27b68e4fe3a770631467c3ad244bd829c7975ce0c"
      ),
      // A command holding every escape that behaves differently between
      // serialisers: a quote, a backslash, a tab, a character outside ASCII and
      // a DEL. Foundation is free to spell any of these its own way; Codex is
      // not, so neither are we.
      (
        "Stop", "a\"b\\c\td\u{E9}\u{7F}", 600,
        "sha256:962212c4ca57386caf902b501af4d8ab4c6736870a6453b59b4ebc011ff65851"
      ),
    ])
  func matchesKnownHashes(event: String, command: String, timeout: Int, expected: String) {
    #expect(
      CodexHookTrust.identityHash(event: event, command: command, timeoutSeconds: timeout)
        == expected)
  }

  /// The two events Codex gives a different default to, because both run during
  /// teardown. Hashing them at 600 would make every SessionEnd and Interrupt
  /// entry read as `modified` — an install accused of having changed when it
  /// never did.
  @Test("teardown events default to a one-second timeout")
  func teardownTimeouts() {
    #expect(CodexHookTrust.defaultTimeoutSeconds(for: "SessionEnd") == 1)
    #expect(CodexHookTrust.defaultTimeoutSeconds(for: "Interrupt") == 1)
    #expect(CodexHookTrust.defaultTimeoutSeconds(for: "Stop") == 600)
    #expect(CodexHookTrust.defaultTimeoutSeconds(for: "PreToolUse") == 600)
  }

  @Test("an event Codex has never heard of gets no hash and no key")
  func unknownEvent() {
    #expect(CodexHookTrust.identityHash(event: "Elevenses", command: "x", timeoutSeconds: 1) == nil)
    #expect(
      CodexHookTrust.stateKey(hooksPath: hooksPath, event: "Elevenses", group: 0, handler: 0)
        == nil)
  }

  /// Every event Vigil registers Codex for has to be one Codex knows, or the
  /// entry is silently ignored and no amount of trusting will help.
  @Test("every event Vigil asks Codex for is one Codex names")
  func vigilsEventsAreReal() {
    for event in AgentIntegration.codex.allEvents {
      #expect(
        CodexHookTrust.eventLabels[event] != nil,
        "\(event) is not in Codex's HookEventsToml and would be dropped from the file")
    }
  }

  @Test("the state key is the path, the snake_case event, and both indices")
  func keyShape() {
    #expect(
      CodexHookTrust.stateKey(
        hooksPath: "/h/hooks.json", event: "UserPromptSubmit", group: 1, handler: 2)
        == "/h/hooks.json:user_prompt_submit:1:2")
  }

  @Test(
    "strings are escaped the way serde_json escapes them",
    arguments: [
      ("plain", "\"plain\""),
      ("a\"b", "\"a\\\"b\""),
      ("a\\b", "\"a\\\\b\""),
      ("a\nb", "\"a\\nb\""),
      ("a\tb", "\"a\\tb\""),
      ("a\u{08}b", "\"a\\bb\""),
      ("a\u{0C}b", "\"a\\fb\""),
      ("a\u{01}b", "\"a\\u0001b\""),
      // Not escaped, either of them: the solidus because serde_json leaves it,
      // and é because the output is UTF-8 rather than escaped ASCII.
      ("a/b", "\"a/b\""),
      ("caf\u{E9}", "\"caf\u{E9}\""),
    ])
  func escaping(input: String, expected: String) {
    #expect(CodexHookTrust.quoted(input) == expected)
  }
}

// MARK: - Reading config.toml

@Suite("Reading Codex's trust records")
struct CodexTrustRecordTests {

  @Test("the standard table form Codex writes")
  func standardTable() {
    let records = CodexHookTrust.trustRecords(inConfigTOML: realConfigTOML)
    #expect(records.count == 5)
    #expect(records["/Users/aniket/.codex/hooks.json:stop:0:0"]?.hasPrefix("sha256:") == true)
  }

  /// A config.toml is a file people hand-edit, so the other two shapes TOML
  /// allows for the same table have to read too. Getting one of them wrong
  /// would mean reporting a trusted install as untrusted — a false accusation,
  /// which is the failure this whole change exists to remove.
  @Test("a dotted key under [hooks.state]")
  func dottedKey() {
    let toml = """
      [hooks.state]
      "/h/hooks.json:stop:0:0".trusted_hash = "sha256:abc"
      "/h/hooks.json:stop:0:1".enabled = false
      """
    #expect(
      CodexHookTrust.trustRecords(inConfigTOML: toml) == ["/h/hooks.json:stop:0:0": "sha256:abc"])
  }

  @Test("an inline table")
  func inlineTable() {
    let toml = """
      [hooks.state]
      "/h/hooks.json:stop:0:0" = { enabled = true, trusted_hash = "sha256:abc" }
      """
    #expect(
      CodexHookTrust.trustRecords(inConfigTOML: toml) == ["/h/hooks.json:stop:0:0": "sha256:abc"])
  }

  @Test("a table that is not hooks.state is not read as one")
  func otherTables() {
    let toml = """
      [model]
      trusted_hash = "sha256:nope"

      [hooks.state."/h/hooks.json:stop:0:0"]
      trusted_hash = "sha256:yes"

      [tui]
      trusted_hash = "sha256:also-nope"
      """
    #expect(
      CodexHookTrust.trustRecords(inConfigTOML: toml) == ["/h/hooks.json:stop:0:0": "sha256:yes"])
  }

  @Test("comments and blank files yield nothing")
  func comments() {
    #expect(CodexHookTrust.trustRecords(inConfigTOML: "").isEmpty)
    #expect(
      CodexHookTrust.trustRecords(
        inConfigTOML: "# [hooks.state.\"/h:stop:0:0\"]\n# trusted_hash = \"sha256:x\""
      ).isEmpty)
  }

  @Test("a key holding a quote survives unquoting")
  func escapedKey() {
    let toml = #"""
      [hooks.state."/h/a\"b/hooks.json:stop:0:0"]
      trusted_hash = "sha256:abc"
      """#
    #expect(
      CodexHookTrust.trustRecords(inConfigTOML: toml)[#"/h/a"b/hooks.json:stop:0:0"#]
        == "sha256:abc")
  }
}

// MARK: - The verdict

@Suite("Whether Codex will run what we installed")
struct CodexTrustStatusTests {

  /// A fresh install into an untouched Codex: every entry present, no record
  /// for any of them, so Codex runs none of them. This is what a user sees the
  /// moment they press "Set up", and Vigil used to call it "Reporting".
  @Test("a brand-new install is untrusted, not ready")
  func freshInstall() {
    let settings = HookConfiguration.install(into: [:], scriptPath: script, integration: .codex)
    let state = CodexHookTrust.status(
      hooks: settings, hooksPath: hooksPath, configTOML: "",
      scriptPath: script, integration: .codex)
    #expect(state == .untrusted(events: AgentIntegration.codex.allEvents.sorted()))
  }

  /// The same install once the user has answered `/hooks`. Built by computing
  /// what Codex would record, which is the only thing `status` is allowed to do
  /// with these hashes — compute them and compare.
  @Test("an install the user has trusted reads as trusted")
  func trustedInstall() {
    let settings = HookConfiguration.install(into: [:], scriptPath: script, integration: .codex)
    let toml = trustEverything(in: settings)
    let state = CodexHookTrust.status(
      hooks: settings, hooksPath: hooksPath, configTOML: toml,
      scriptPath: script, integration: .codex)
    #expect(state == .trusted)
    #expect(state.isSatisfied)
    #expect(state.explanation(host: "Codex") == nil)
  }

  /// Trusted, then the script moved. Codex keeps the old record, sees a hash it
  /// does not match, and stops running a hook it used to run — a live install
  /// going quiet with nothing on screen to say so.
  @Test("a trusted install whose command changed reads as modified")
  func modifiedInstall() {
    let settings = HookConfiguration.install(into: [:], scriptPath: script, integration: .codex)
    let toml = trustEverything(in: settings)
    let moved = HookConfiguration.install(
      into: [:], scriptPath: "/Applications/Vigil.app/hooks/vigil-hook.sh", integration: .codex)

    let state = CodexHookTrust.status(
      hooks: moved, hooksPath: hooksPath, configTOML: toml,
      scriptPath: "/Applications/Vigil.app/hooks/vigil-hook.sh", integration: .codex)

    #expect(state == .modified(events: AgentIntegration.codex.allEvents.sorted()))
    #expect(!state.isSatisfied)
    #expect(state.explanation(host: "Codex")?.contains("/hooks") == true)
  }

  /// Re-running the install must not cost the user their trust decision. It
  /// writes the same command at the same index, so the hash is the same and the
  /// records still apply — which is the only reason "Update" is a safe button
  /// to offer a Codex user at all.
  @Test("reinstalling over a trusted install stays trusted")
  func reinstallKeepsTrust() {
    let first = HookConfiguration.install(into: [:], scriptPath: script, integration: .codex)
    let toml = trustEverything(in: first)
    let again = HookConfiguration.install(into: first, scriptPath: script, integration: .codex)

    #expect(
      CodexHookTrust.status(
        hooks: again, hooksPath: hooksPath, configTOML: toml,
        scriptPath: script, integration: .codex) == .trusted)
  }

  /// Only the trusted half counts. Half-answered is still a host that will not
  /// run everything we asked for, and it is named down to the event.
  @Test("a partly trusted install names only the entries that are not")
  func partiallyTrusted() {
    let settings = HookConfiguration.install(into: [:], scriptPath: script, integration: .codex)
    var records = trustRecordLines(in: settings)
    records.removeValue(forKey: "/Users/aniket/.codex/hooks.json:stop:0:0")

    let state = CodexHookTrust.status(
      hooks: settings, hooksPath: hooksPath, configTOML: render(records),
      scriptPath: script, integration: .codex)
    #expect(state == .untrusted(events: ["Stop"]))
  }

  @Test(
    "the three hosts with no gate are never asked",
    arguments: [
      AgentIntegration.claudeCode, .gemini, .cursor,
    ])
  func hostsWithoutAGate(integration: AgentIntegration) {
    #expect(!integration.requiresHookTrust)
    let settings = HookConfiguration.install(
      into: [:], scriptPath: script, integration: integration)
    let state = CodexHookTrust.status(
      hooks: settings, hooksPath: hooksPath, configTOML: "",
      scriptPath: script, integration: integration)
    #expect(state == .notRequired)
    #expect(state.isSatisfied)
    #expect(
      HookConfiguration.setupState(
        missingEvents: [], expectedEvents: integration.allEvents, trust: state) == .ready)
  }

  /// Nothing of ours in the file is not the trust check's question to answer —
  /// `missingEvents` already has it, and reporting "untrusted" for an agent
  /// that was never set up would put the wrong sentence on screen.
  @Test("an agent that was never set up is unknown rather than untrusted")
  func nothingInstalled() {
    #expect(
      CodexHookTrust.status(
        hooks: ["theme": "dark"], hooksPath: hooksPath, configTOML: "",
        scriptPath: script, integration: .codex) == .unknown)
  }

  /// An entry carrying a key we do not know how to hash would hash to something
  /// other than what Codex computes, and a wrong hash reads as `modified`. Say
  /// nothing instead.
  @Test("an entry in a shape we cannot hash is unknown, not an accusation")
  func unhashableEntry() {
    let json = """
      {"hooks":{"Stop":[{"hooks":[{"type":"command",
      "command":"'\(script)' codex Stop idle","statusMessage":"checking"}]}]}}
      """
    let state = CodexHookTrust.status(
      hooks: parse(json), hooksPath: hooksPath, configTOML: "",
      scriptPath: script, integration: .codex)
    #expect(state == .unknown)
    #expect(state.isSatisfied, "an unreadable gate must never hold an install back")
  }

  /// A matcher string is part of what Codex hashes. Vigil never writes one, so
  /// a group carrying one is not a group we put there and not one we can speak
  /// for — it is skipped rather than hashed without it.
  @Test("a group with a matcher is not treated as ours")
  func matcherGroup() {
    let json = """
      {"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"type":"command",
      "command":"'\(script)' codex Stop idle"}]}]}}
      """
    let state = CodexHookTrust.status(
      hooks: parse(json), hooksPath: hooksPath, configTOML: "",
      scriptPath: script, integration: .codex)
    #expect(state == .unknown)
  }

  // MARK: Helpers

  /// The records Codex would write if the user trusted every one of our
  /// entries. Deliberately built from `entries` and `identityHash` — the
  /// alternative is a table of literals that would have to be recomputed every
  /// time the command string changes, and would then be testing the table.
  private func trustRecordLines(in settings: [String: Any]) -> [String: String] {
    var records: [String: String] = [:]
    for entry in CodexHookTrust.entries(
      in: settings, scriptPath: script, integration: .codex) ?? []
    {
      guard
        let key = CodexHookTrust.stateKey(
          hooksPath: hooksPath, event: entry.event, group: entry.group, handler: entry.handler),
        let hash = CodexHookTrust.identityHash(
          event: entry.event, command: entry.command, timeoutSeconds: entry.timeoutSeconds)
      else { continue }
      records[key] = hash
    }
    return records
  }

  private func trustEverything(in settings: [String: Any]) -> String {
    render(trustRecordLines(in: settings))
  }

  private func render(_ records: [String: String]) -> String {
    records.keys.sorted()
      .map { "[hooks.state.\"\($0)\"]\ntrusted_hash = \"\(records[$0]!)\"\n" }
      .joined(separator: "\n")
  }
}

/// The machine's real `hooks.json`, captured beside the config.toml above.
///
/// Another tool registered first, so its entries hold matcher index 0 on the
/// five events both tools want; Vigil's were appended and sit at index 1.
/// `Interrupt` and `SessionEnd` are Vigil's alone, at index 0 — and have no
/// record either, which is what makes "five records, seven entries" a
/// coincidence of counting rather than a description of the problem.
private let realHooksJSON = """
  {
    "hooks": {
      "Interrupt": [
        { "hooks": [{ "command": "'\(script)' codex Interrupt idle", "type": "command" }] }
      ],
      "PostToolUse": [
        { "hooks": [{ "command": "/Users/aniket/.holdmylid/hooks/codex-notify-hook.sh PostToolUse", "type": "command" }] },
        { "hooks": [{ "command": "'\(script)' codex PostToolUse working", "type": "command" }] }
      ],
      "PreToolUse": [
        { "hooks": [{ "command": "/Users/aniket/.holdmylid/hooks/codex-notify-hook.sh PreToolUse", "type": "command" }] },
        { "hooks": [{ "command": "'\(script)' codex PreToolUse working", "type": "command" }] }
      ],
      "SessionEnd": [
        { "hooks": [{ "command": "'\(script)' codex SessionEnd idle", "type": "command" }] }
      ],
      "SessionStart": [
        { "hooks": [{ "command": "/Users/aniket/.holdmylid/hooks/codex-notify-hook.sh SessionStart", "type": "command" }] },
        { "hooks": [{ "command": "'\(script)' codex SessionStart idle", "type": "command" }] }
      ],
      "Stop": [
        { "hooks": [{ "command": "/Users/aniket/.holdmylid/hooks/codex-notify-hook.sh Stop", "type": "command" }] },
        { "hooks": [{ "command": "'\(script)' codex Stop idle", "type": "command" }] }
      ],
      "UserPromptSubmit": [
        { "hooks": [{ "command": "/Users/aniket/.holdmylid/hooks/codex-notify-hook.sh UserPromptSubmit", "type": "command" }] },
        { "hooks": [{ "command": "'\(script)' codex UserPromptSubmit working", "type": "command" }] }
      ]
    }
  }
  """
