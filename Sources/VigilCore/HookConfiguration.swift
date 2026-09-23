import CryptoKit
import Foundation

/// Merging Vigil's hooks into an agent's settings file.
///
/// Pure JSON transformation, kept here rather than in the app layer because
/// editing someone's editor configuration is exactly the kind of thing that
/// must be tested before it ever runs. The rules: never drop a setting we
/// don't understand, never install twice, and always be removable.
public enum HookConfiguration {

  /// A hook entry is ours if its command invokes our script.
  ///
  /// Matched on the script's *filename*, not its full path: the app can move
  /// between builds and installs, and matching the whole path would leave the
  /// old entry behind so every event fired twice. The filename is distinctive
  /// enough to be safe.
  public static func isVigilHook(_ command: String, scriptPath: String) -> Bool {
    let name = (scriptPath as NSString).lastPathComponent
    guard !name.isEmpty else { return false }
    return command.contains(name)
  }

  /// Whether a hook entry is one of ours, in either shape a host might use.
  static func isOurs(_ matcher: [String: Any], scriptPath: String) -> Bool {
    if let command = matcher["command"] as? String {
      return isVigilHook(command, scriptPath: scriptPath)
    }
    guard let inner = matcher["hooks"] as? [[String: Any]] else { return false }
    return inner.contains { entry in
      (entry["command"] as? String).map { isVigilHook($0, scriptPath: scriptPath) } ?? false
    }
  }

  /// Whether a value is really absent.
  ///
  /// A JSON `null` survives `JSONSerialization` as `NSNull`, which is not nil,
  /// so `settings["hooks"] != nil` is true for a file that says
  /// `"hooks": null` — a file with nothing in it to protect.
  private static func isAbsent(_ value: Any?) -> Bool {
    value == nil || value is NSNull
  }

  /// The keys whose existing value Vigil cannot merge into.
  ///
  /// Empty for every settings file shaped the way its host documents. A
  /// non-empty result means someone's file holds a `hooks` container, or one
  /// event inside it, in a shape we have never seen — most likely another
  /// tool's convention, possibly a typo. Either way it is theirs. `install`
  /// leaves those alone rather than replacing them, and the installer refuses
  /// with this list so the refusal can name what it found instead of quietly
  /// wiring up everything except the one entry that mattered.
  public static func unmergeableKeys(
    in settings: [String: Any],
    integration: AgentIntegration
  ) -> [String] {
    let container = settings["hooks"]
    if !isAbsent(container), container as? [String: Any] == nil { return ["hooks"] }
    let hooks = container as? [String: Any] ?? [:]
    return integration.allEvents.filter { event in
      !isAbsent(hooks[event]) && hooks[event] as? [[String: Any]] == nil
    }
  }

  /// Add an agent's hooks to its settings, leaving everything else alone.
  ///
  /// The event-to-state mapping is baked into the command at install time
  /// (`vigil-hook.sh <agent> <event> <state>`) rather than branching inside the
  /// shell script. That keeps one script for every agent and keeps the mapping
  /// here, where it is typed and tested.
  ///
  /// Idempotent: installing twice produces the same result as installing once.
  public static func install(
    into settings: [String: Any],
    scriptPath: String,
    integration: AgentIntegration
  ) -> [String: Any] {
    var settings = settings
    // "Never drop a setting we don't understand" has to hold for the hook
    // container too. A `hooks` key that is not an object was being replaced
    // wholesale, which is the one thing this file promises not to do.
    if !isAbsent(settings["hooks"]), settings["hooks"] as? [String: Any] == nil { return settings }
    var hooks = settings["hooks"] as? [String: Any] ?? [:]

    // Sweep our hooks out of *every* event first, not just the ones about to be
    // rewritten. Vigil's event set shrinks as well as grows — Cursor's four
    // permission hooks were retired because registering on them blocked the
    // agent — and the loop below only ever visits events we still want, so a
    // retired entry was never touched again. It sat in the user's settings
    // firing forever, which for those four meant staying armed and blocking.
    for (event, value) in hooks {
      guard let matchers = value as? [[String: Any]] else { continue }
      let theirs = matchers.filter { !isOurs($0, scriptPath: scriptPath) }
      if theirs.isEmpty {
        hooks.removeValue(forKey: event)
      } else if theirs.count != matchers.count {
        hooks[event] = theirs
      }
    }

    for event in integration.allEvents {
      // The same rule one level down. `hooks[event] as? [[String: Any]] ?? []`
      // read another tool's differently-shaped entry as an empty slot and wrote
      // over it, so installing Vigil silently deleted their hook.
      if !isAbsent(hooks[event]), hooks[event] as? [[String: Any]] == nil { continue }

      let state = integration.state(for: event)
      // The sweep above has already taken our old entries out of this event,
      // so a changed script path replaces the previous one rather than
      // accumulating beside it. The check that finds them is shape-aware; the
      // nested-only version it replaced silently missed Cursor's flat entries,
      // which is how Cursor came to duplicate its hooks on every install.
      var matchers = hooks[event] as? [[String: Any]] ?? []

      // Quoted: an unquoted path containing a space made the shell try to run
      // its first word, so every hook failed silently.
      let command = "'\(scriptPath)' \(integration.id.rawValue) \(event) \(state.rawValue)"

      switch integration.entryFormat {
      case .nested:
        var entry: [String: Any] = ["type": "command", "command": command]
        if let timeout = integration.timeoutMilliseconds { entry["timeout"] = timeout }
        matchers.append(["hooks": [entry]])
      case .flat:
        var entry: [String: Any] = ["command": command]
        if let timeout = integration.timeoutMilliseconds { entry["timeout"] = timeout }
        matchers.append(entry)
      }
      hooks[event] = matchers
    }

    settings["hooks"] = hooks
    return settings
  }

  /// Remove Vigil's hooks, leaving every other hook intact.
  ///
  /// Prunes empty containers so uninstalling returns the file to its original
  /// shape rather than leaving `"hooks": {}` behind.
  public static func uninstall(
    from settings: [String: Any],
    scriptPath: String
  ) -> [String: Any] {
    var settings = settings
    guard var hooks = settings["hooks"] as? [String: Any] else { return settings }

    for (event, value) in hooks {
      guard var matchers = value as? [[String: Any]] else { continue }

      matchers = matchers.filter { !isOurs($0, scriptPath: scriptPath) }

      if matchers.isEmpty {
        hooks.removeValue(forKey: event)
      } else {
        hooks[event] = matchers
      }
    }

    if hooks.isEmpty {
      settings.removeValue(forKey: "hooks")
    } else {
      settings["hooks"] = hooks
    }
    return settings
  }

  /// Whether our hooks are already present for every event we want.
  public static func isInstalled(
    in settings: [String: Any],
    scriptPath: String,
    integration: AgentIntegration
  ) -> Bool {
    missingEvents(in: settings, scriptPath: scriptPath, integration: integration).isEmpty
  }

  /// The events we expect a hook for and did not find one.
  ///
  /// `isInstalled` is the same question asked as a yes or no, but the list is
  /// what makes a half-installed agent explicable: when Vigil's expected event
  /// set grows between versions, an older install fails the yes/no check with
  /// nothing to say about *why*, and the panel quietly under-reports.
  public static func missingEvents(
    in settings: [String: Any],
    scriptPath: String,
    integration: AgentIntegration
  ) -> [String] {
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    return integration.allEvents.filter { event in
      guard let matchers = hooks[event] as? [[String: Any]] else { return true }
      return !matchers.contains { isOurs($0, scriptPath: scriptPath) }
    }
  }

  /// Our hooks that are registered for events we no longer listen for.
  ///
  /// The mirror image of `missingEvents`, and it needs its own answer. Vigil's
  /// event set shrinks as well as grows — Cursor's four permission hooks were
  /// retired because being registered on them blocked the agent — and an
  /// install that is missing nothing looks entirely healthy to
  /// `missingEvents`, so nothing ever prompts the user to re-run setup and the
  /// retired entries keep firing. Today's shrink happens to add `sessionEnd`
  /// alongside, which drags every Cursor install into `outOfDate` by the other
  /// route; that is luck, not design, and this is the design.
  public static func retiredEvents(
    in settings: [String: Any],
    scriptPath: String,
    integration: AgentIntegration
  ) -> [String] {
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    let wanted = Set(integration.allEvents)
    return hooks.keys.sorted().filter { event in
      guard !wanted.contains(event),
        let matchers = hooks[event] as? [[String: Any]]
      else { return false }
      return matchers.contains { isOurs($0, scriptPath: scriptPath) }
    }
  }
}

/// What an agent's hook setup looks like from the user's side.
public enum HookSetupState: Sendable, Equatable {
  /// Wired up for everything we listen for.
  case ready
  /// Events are arriving, but not every hook we now expect is registered —
  /// an install from an older version of Vigil. This is the case that used to
  /// be invisible: the agent is plainly working, so it never appeared in the
  /// "needs setting up" list, and the panel silently reported less than the
  /// truth.
  case outOfDate
  /// Never wired up, and not reporting.
  case notSetUp
}

/// Whether the host will actually run the hooks we wrote into its settings.
///
/// A different question from "are our hooks in the file", and it has to be
/// asked separately because for one host the answer to the first tells you
/// nothing about the second. Codex records a `trusted_hash` per hook entry and
/// drops every entry without a matching one before it assembles the handlers
/// it will run, so a file Vigil has just written perfectly is a file Codex
/// ignores completely — and Vigil reported that as "Reporting".
///
/// Its own vocabulary, kept deliberately: `untrusted` and `modified` are what
/// Codex calls these two, so anyone comparing this against `/hooks` is reading
/// the same words on both sides.
public enum HookTrustState: Sendable, Equatable {
  /// This host runs what its settings file says. Nothing else to satisfy.
  case notRequired
  /// Every entry of ours carries a trust record that matches what is installed.
  case trusted
  /// Entries the host holds no trust record for at all. It will not run them.
  case untrusted(events: [String])
  /// Entries whose trust record no longer matches what is installed — the hook
  /// was trusted once and has changed since. The host will not run these
  /// either, and says so more loudly than it says `untrusted`.
  case modified(events: [String])
  /// The gate exists, and we could not read it.
  ///
  /// Never reported as a problem. A trust file in a shape we do not recognise
  /// is a reason to say nothing, not a reason to accuse a working install —
  /// the whole point of this type is to stop Vigil making claims it cannot
  /// support, and that cuts both ways.
  case unknown

  /// Whether the host will run every hook we installed.
  ///
  /// `unknown` counts as satisfied on purpose: see above.
  public var isSatisfied: Bool {
    switch self {
    case .notRequired, .trusted, .unknown: true
    case .untrusted, .modified: false
    }
  }

  /// The events this host is refusing to run, named. Empty when it is running
  /// all of them, or when we cannot tell.
  public var blockedEvents: [String] {
    switch self {
    case .notRequired, .trusted, .unknown: []
    case .untrusted(let events), .modified(let events): events
    }
  }

  /// What to tell the user, or nil when there is nothing to tell them.
  ///
  /// Written here rather than in the panel for the same reason `WakeReason`'s
  /// wording is: it is a claim about how another program behaves, so it should
  /// sit beside the check that establishes it and be testable. Both sentences
  /// name `/hooks`, because that is the Codex command that fixes this and a
  /// notice the user cannot act on is only a nicer way of saying nothing.
  public func explanation(host: String) -> String? {
    switch self {
    case .notRequired, .trusted, .unknown:
      nil
    case .untrusted:
      "\(host) hasn't been told to trust Vigil's hooks, so it isn't running them. "
        + "Open \(host) and run /hooks to review them."
    case .modified:
      "\(host) trusted Vigil's hooks before they changed, so it has stopped running them. "
        + "Open \(host) and run /hooks to review them."
    }
  }
}

/// Codex's per-entry hook trust, read rather than guessed at.
///
/// Codex will not run a hook it has not been told to trust. It keeps the
/// decision in `~/.codex/config.toml`:
///
///     [hooks.state."/Users/x/.codex/hooks.json:post_tool_use:0:0"]
///     trusted_hash = "sha256:2e0a4c…"
///
/// The key is `<hooks file>:<event>:<matcher index>:<handler index>` and the
/// event is snake_case, neither of which is the spelling used inside
/// `hooks.json` — so the same entry is named two different ways in the two
/// files, and eyeballing them against each other does not work.
///
/// The hash is over a normalised identity for the entry rather than over the
/// file's text, so that the same hook written in `config.toml` and in
/// `hooks.json` lands on one trust record. `identityHash` reproduces it, and
/// the reproduction is checked against the five records on a real machine in
/// `CodexHookTrustTests` — this is a claim about somebody else's program, and
/// the only honest way to make it is to run it against that program's output.
///
/// None of this writes anything. Forging a trust record would defeat the
/// mechanism exactly: the point of the gate is that a human looked at the
/// command before it ran with their shell.
public enum CodexHookTrust {

  /// Codex's own name for an event inside a state key.
  ///
  /// A table rather than a camel-to-snake conversion, and not for neatness:
  /// Codex's `HookEventsToml` has one field per event and ignores every other
  /// key in the file, so these twelve are the whole vocabulary. Converting
  /// mechanically would happily produce a plausible label for an event Codex
  /// has never heard of, and we would then report a missing trust record for a
  /// hook that was never going to run under any name.
  static let eventLabels: [String: String] = [
    "PreToolUse": "pre_tool_use",
    "PermissionRequest": "permission_request",
    "PostToolUse": "post_tool_use",
    "PreCompact": "pre_compact",
    "PostCompact": "post_compact",
    "SessionStart": "session_start",
    "SessionEnd": "session_end",
    "UserPromptSubmit": "user_prompt_submit",
    "SubagentStart": "subagent_start",
    "SubagentStop": "subagent_stop",
    "Stop": "stop",
    "Interrupt": "interrupt",
  ]

  /// Codex's default timeout for an event, in seconds.
  ///
  /// Part of the hashed identity, so getting it wrong makes every hash wrong.
  /// Codex resolves the default before hashing — an entry with no `timeout` is
  /// hashed as though it had the default written in — and `SessionEnd` and
  /// `Interrupt` have their own, because both run during teardown and have to
  /// finish inside the shutdown budget.
  static func defaultTimeoutSeconds(for event: String) -> Int {
    (event == "SessionEnd" || event == "Interrupt") ? 1 : 600
  }

  /// The key Codex files this entry's trust decision under.
  public static func stateKey(
    hooksPath: String, event: String, group: Int, handler: Int
  ) -> String? {
    guard let label = eventLabels[event] else { return nil }
    return "\(hooksPath):\(label):\(group):\(handler)"
  }

  /// The hash Codex computes for one command hook.
  ///
  /// Codex builds a normalised identity, turns it into a TOML value, converts
  /// that to JSON, sorts every object's keys, serialises compactly and takes
  /// SHA-256 of the bytes. Two details do the work and both are load-bearing:
  /// the round trip through TOML *drops* every absent optional, because TOML
  /// cannot hold a null; and the sort is what makes the result independent of
  /// the order anything was written in.
  ///
  /// So for a hook with no matcher and nothing but a command, the bytes are
  /// exactly:
  ///
  ///     {"event_name":"stop","hooks":[{"async":false,"command":"…",
  ///      "timeout":600,"type":"command"}]}
  ///
  /// Hand-assembled rather than run through `JSONSerialization`, because the
  /// bytes have to match another program's serialiser and not merely be valid
  /// JSON. Foundation gives no promise about how it escapes, and a single
  /// differently-spelled escape would turn every answer here into a false
  /// accusation.
  static func identityHash(event: String, command: String, timeoutSeconds: Int) -> String? {
    guard let label = eventLabels[event] else { return nil }
    let json =
      "{\"event_name\":\(quoted(label)),\"hooks\":[{\"async\":false,"
      + "\"command\":\(quoted(command)),\"timeout\":\(timeoutSeconds),\"type\":\"command\"}]}"
    let digest = SHA256.hash(data: Data(json.utf8))
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  /// A JSON string literal escaped the way `serde_json` escapes one.
  ///
  /// Quote and backslash, the five named control escapes, `\u00xx` in lowercase
  /// hex for the rest of C0 — and nothing else. Notably *not* the solidus, and
  /// notably not any non-ASCII character: those go through as UTF-8, which is
  /// why a hook script living under a path with an accent in it still hashes
  /// correctly.
  static func quoted(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }

  /// Every `trusted_hash` in a `config.toml`, keyed the way Codex keys them.
  ///
  /// A reader for one table rather than a TOML parser, which is the right size
  /// for the job: this needs `hooks.state` and nothing else, and a general
  /// parser would be a great deal of surface area to maintain in a menu bar
  /// app for one lookup. It reads the three shapes the table can take — the
  /// standard-table form Codex itself writes, a dotted key under
  /// `[hooks.state]`, and an inline table — and anything else it simply does
  /// not see, which `status` then reports as `unknown` rather than as trouble.
  static func trustRecords(inConfigTOML toml: String) -> [String: String] {
    var records: [String: String] = [:]
    /// The `[hooks.state."…"]` table we are currently inside, if any.
    var currentKey: String?
    var insideStateTable = false

    for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#") { continue }

      if line.hasPrefix("[") {
        currentKey = nil
        insideStateTable = false
        let header = String(line.dropFirst().prefix(while: { $0 != "]" }))
          .trimmingCharacters(in: .whitespaces)
        if header == "hooks.state" {
          insideStateTable = true
        } else if header.hasPrefix("hooks.state.") {
          currentKey = unquote(String(header.dropFirst("hooks.state.".count)))
        }
        continue
      }

      guard let equals = line.firstIndex(of: "=") else { continue }
      let name = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)

      if let currentKey, name == "trusted_hash" {
        records[currentKey] = unquote(value)
      } else if insideStateTable {
        // `"key".trusted_hash = "…"`, or `"key" = { trusted_hash = "…" }`.
        if name.hasSuffix(".trusted_hash") {
          records[unquote(String(name.dropLast(".trusted_hash".count)))] = unquote(value)
        } else if value.hasPrefix("{"), let hash = inlineTrustedHash(value) {
          records[unquote(name)] = hash
        }
      }
    }
    return records
  }

  /// `trusted_hash` out of `{ enabled = true, trusted_hash = "…" }`.
  private static func inlineTrustedHash(_ value: String) -> String? {
    guard let range = value.range(of: "trusted_hash") else { return nil }
    let rest = value[range.upperBound...].drop { $0 == " " || $0 == "=" }
    guard rest.first == "\"" || rest.first == "'" else { return nil }
    let quote = rest.first!
    let body = rest.dropFirst().prefix { $0 != quote }
    return body.isEmpty ? nil : String(body)
  }

  /// Strip one layer of TOML quoting from a key or a value.
  ///
  /// Basic strings honour `\\` and `\"`; literal strings — single quotes — mean
  /// exactly what they say, which is why a Windows path in a key survives.
  static func unquote(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespaces)
    if let comment = text.firstIndex(of: "#"), !text.hasPrefix("\""), !text.hasPrefix("'") {
      text = String(text[text.startIndex..<comment]).trimmingCharacters(in: .whitespaces)
    }
    if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 {
      return String(text.dropFirst().dropLast())
    }
    guard text.hasPrefix("\""), text.count >= 2 else { return text }
    var out = ""
    var escaped = false
    for character in text.dropFirst() {
      if escaped {
        switch character {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        default: out.append(character)
        }
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        break
      } else {
        out.append(character)
      }
    }
    return out
  }

  /// Where each of our hook entries sits in a hooks file, and what it says.
  ///
  /// The indices are the whole point. Codex keys trust on *position* — matcher
  /// index, then handler index — so an entry of ours that shares an event with
  /// another tool's hook is at index 1, and the trust record at index 0 belongs
  /// to the other tool no matter how much it looks like ours at a glance.
  struct Entry {
    let event: String
    let group: Int
    let handler: Int
    let command: String
    let timeoutSeconds: Int
  }

  /// Our entries in a parsed `hooks.json`, with their positions.
  ///
  /// Returns nil for any entry carrying a key we do not know how to hash. An
  /// unexpected key changes the bytes Codex hashes, so a hash computed without
  /// it would be wrong, and a wrong hash reads as `modified` — an accusation.
  /// Better to say we do not know.
  static func entries(
    in settings: [String: Any], scriptPath: String, integration: AgentIntegration
  ) -> [Entry]? {
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    var found: [Entry] = []

    for event in integration.allEvents.sorted() {
      guard let matchers = hooks[event] as? [[String: Any]] else { continue }
      for (group, matcher) in matchers.enumerated() {
        // A matcher string is part of the hashed identity and Vigil never
        // writes one, so a group carrying anything but `hooks` is not a group
        // we can speak for.
        guard Set(matcher.keys) == ["hooks"],
          let handlers = matcher["hooks"] as? [[String: Any]]
        else { continue }
        for (handler, entry) in handlers.enumerated() {
          guard let command = entry["command"] as? String,
            HookConfiguration.isVigilHook(command, scriptPath: scriptPath)
          else { continue }
          guard Set(entry.keys).isSubset(of: ["type", "command", "timeout"]) else { return nil }
          let timeout = entry["timeout"] as? Int ?? defaultTimeoutSeconds(for: event)
          found.append(
            Entry(
              event: event, group: group, handler: handler, command: command,
              timeoutSeconds: max(1, timeout)))
        }
      }
    }
    return found
  }

  /// Whether Codex will run the hooks in this `hooks.json`.
  ///
  /// `configTOML` is the text of `~/.codex/config.toml`. Passed in rather than
  /// read here because VigilCore does no I/O — and because a check that takes
  /// its evidence as an argument is a check that can be tested against a real
  /// machine's file without ever opening one.
  public static func status(
    hooks settings: [String: Any],
    hooksPath: String,
    configTOML: String,
    scriptPath: String,
    integration: AgentIntegration
  ) -> HookTrustState {
    guard integration.requiresHookTrust else { return .notRequired }
    guard let ours = entries(in: settings, scriptPath: scriptPath, integration: integration),
      !ours.isEmpty
    else { return .unknown }

    let records = trustRecords(inConfigTOML: configTOML)
    var untrusted: [String] = []
    var modified: [String] = []

    for entry in ours {
      guard
        let key = stateKey(
          hooksPath: hooksPath, event: entry.event, group: entry.group, handler: entry.handler),
        let expected = identityHash(
          event: entry.event, command: entry.command, timeoutSeconds: entry.timeoutSeconds)
      else { return .unknown }

      guard let recorded = records[key] else {
        untrusted.append(entry.event)
        continue
      }
      if recorded != expected { modified.append(entry.event) }
    }

    // Reported separately because they mean different things to the user: one
    // has never been looked at, the other was looked at and has changed since.
    // `modified` leads when both are present — it is the more surprising of the
    // two, and the one that says an install which used to work has stopped.
    if !modified.isEmpty { return .modified(events: modified.sorted()) }
    if !untrusted.isEmpty { return .untrusted(events: untrusted.sorted()) }
    return .trusted
  }
}

extension HookConfiguration {
  /// Classify an agent from what its settings file actually contains.
  ///
  /// The distinction that matters is between "never set up" and "set up by a
  /// version of Vigil that listened for a different set of events", and it is
  /// readable straight off the file: some of our hooks present and some absent
  /// can only be an older install.
  ///
  /// Deliberately not a function of whether the agent is currently reporting.
  /// Tying it to live sessions meant an agent kept its out-of-date badge for
  /// the whole staleness window after the user had just removed it — pressing
  /// them to reinstall what they had deliberately taken out.
  /// `retiredEvents` is defaulted so the existing call sites keep their meaning:
  /// an install can also be out of date by holding hooks for events Vigil has
  /// since stopped listening for, and that is still an install to re-run.
  ///
  /// `trust` is the other half of the question and the reason this function
  /// grew a third default argument. Everything above reads Vigil's own wiring;
  /// `trust` reads whether the host will run it. An install can be complete,
  /// current, and completely inert — which is what Codex does to an entry it
  /// has no `trusted_hash` for, and what Vigil was reporting as `.ready`.
  ///
  /// A host refusing to run our hooks folds into `.outOfDate` rather than
  /// getting a case of its own, and that is a seam rather than a judgement.
  /// `HookSetupState` wants a fourth case here — `notTrusted`, with
  /// `HookTrustState.explanation(host:)` as its sentence — but adding one is a
  /// source break for every exhaustive switch over it, and the two that exist
  /// are in `Sources/Vigil/UI`, which this change does not own. `.outOfDate` is
  /// the closest of the three that exist: it puts the agent in the "needs
  /// attention" bucket and takes "Reporting" off the screen, which is the
  /// actual lie. It still offers to re-run the install, and re-running the
  /// install will not fix this — only the user trusting the hook in the host
  /// will. That last sentence is what the fourth case is for.
  public static func setupState(
    missingEvents: [String],
    expectedEvents: [String],
    retiredEvents: [String] = [],
    trust: HookTrustState = .notRequired
  ) -> HookSetupState {
    if missingEvents.isEmpty {
      if !trust.isSatisfied { return .outOfDate }
      return retiredEvents.isEmpty ? .ready : .outOfDate
    }
    // Hooks left over from a previous version are proof this agent was set up
    // once, whatever else is missing now.
    if !retiredEvents.isEmpty { return .outOfDate }
    if missingEvents.count < expectedEvents.count { return .outOfDate }
    return .notSetUp
  }
}
