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
  /// Installed correctly, and the host is refusing to run it.
  ///
  /// Deliberately not folded into `outOfDate`. The two look the same in the
  /// panel — an agent needing attention — but they are fixed by opposite
  /// actions, and offering the wrong one is worse than offering none: someone
  /// pressing "Update" on an untrusted hook re-installs a file that was never
  /// the problem, watches nothing change, and has no reason to suspect their
  /// host is the thing holding it back.
  case untrusted
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

/// Enough of TOML's shape to find one table, and nothing beyond that.
///
/// Reading `config.toml` and writing it used to be two scans with a
/// `split(separator: "\n")` each, and two copies of the same logic share every
/// blind spot: a CRLF file never split at all — `"\r\n"` is a *single* Swift
/// `Character` — so the reader saw no records, reported "untrusted", and the
/// writer then appended a table that was already in the file. One scanner used
/// by both is the fix for that whole class: the reader can no longer see less
/// than the writer, and what the scanner cannot account for the writer refuses
/// to write beside rather than guessing.
///
/// It is a scanner for statements, not a TOML parser. It resolves key syntax
/// and where a statement ends — a value may span lines, and a line beginning
/// with `[` inside one is not a table header — and it knows nothing about
/// types, defaults or what a document means. Anything it cannot account for
/// ends the scan with `isComplete` false instead of being guessed at, which is
/// what lets `CodexTrustWriter` refuse. Refusing costs the user one `/hooks`
/// command; a wrong guess costs them every hook Codex would have run.
enum CodexTOML {

  /// One physical line, with the ending it arrived with.
  ///
  /// Terminators are carried rather than normalised so a file can be rebuilt
  /// byte for byte, and lines are cut on the newline *scalar*: anything that
  /// goes through `Character` treats CRLF as one element and never cuts at all.
  struct Line: Equatable {
    var text: String
    var terminator: String
  }

  /// One statement, and the physical lines it occupies.
  enum Element {
    /// `[a.b.c]`, with every part of the key path unquoted.
    case header(path: [String], line: Int)
    /// `[[a.b.c]]`. Never a table this writer can add a key to.
    case arrayHeader(path: [String], line: Int)
    /// `key = value`, occupying `first` through `last` inclusive.
    case assignment(path: [String], value: String, first: Int, last: Int)
  }

  /// What a scan found, and whether it got to the end.
  struct Scan {
    var elements: [Element]
    /// False once the scanner met something it could not account for.
    /// `elements` then stops there and says nothing about the rest of the file.
    var isComplete: Bool
  }

  // MARK: - Lines

  /// Split into physical lines, keeping each line's ending.
  static func lines(of toml: String) -> [Line] {
    var out: [Line] = []
    var current = String.UnicodeScalarView()
    for scalar in toml.unicodeScalars {
      guard scalar == "\n" else {
        current.append(scalar)
        continue
      }
      if current.last == "\r" {
        current.removeLast()
        out.append(Line(text: String(current), terminator: "\r\n"))
      } else {
        out.append(Line(text: String(current), terminator: "\n"))
      }
      current = String.UnicodeScalarView()
    }
    if !current.isEmpty { out.append(Line(text: String(current), terminator: "")) }
    return out
  }

  /// The file those lines came from, byte for byte.
  static func joined(_ lines: [Line]) -> String {
    var out = ""
    for line in lines {
      out += line.text
      out += line.terminator
    }
    return out
  }

  /// The ending to give a line we add: whichever the file already uses most.
  static func dominantTerminator(_ lines: [Line]) -> String {
    var crlf = 0
    var lf = 0
    for line in lines {
      if line.terminator == "\r\n" {
        crlf += 1
      } else if line.terminator == "\n" {
        lf += 1
      }
    }
    return crlf > lf ? "\r\n" : "\n"
  }

  // MARK: - Scanning

  /// Every statement in the file, in order.
  static func scan(_ lines: [Line]) -> Scan {
    var elements: [Element] = []
    var index = 0

    while index < lines.count {
      guard isScannable(lines[index]) else { return Scan(elements: elements, isComplete: false) }
      let scalars = Array(lines[index].text.unicodeScalars)
      var cursor = 0
      skipBlanks(scalars, &cursor)
      if cursor == scalars.count || scalars[cursor] == "#" {
        index += 1
        continue
      }

      if scalars[cursor] == "[" {
        guard let header = parseHeader(scalars, from: cursor) else {
          return Scan(elements: elements, isComplete: false)
        }
        elements.append(
          header.isArray
            ? .arrayHeader(path: header.path, line: index)
            : .header(path: header.path, line: index))
        index += 1
        continue
      }

      guard let path = parseKeyPath(scalars, &cursor), !path.isEmpty,
        cursor < scalars.count, scalars[cursor] == "="
      else { return Scan(elements: elements, isComplete: false) }
      cursor += 1

      var value = text(scalars[cursor...])
      var reader = ValueScanner()
      guard reader.consume(scalars, from: cursor) else {
        return Scan(elements: elements, isComplete: false)
      }
      var last = index
      while !reader.isComplete {
        last += 1
        guard last < lines.count, isScannable(lines[last]) else {
          return Scan(elements: elements, isComplete: false)
        }
        value += "\n" + lines[last].text
        guard reader.consume(Array(lines[last].text.unicodeScalars), from: 0) else {
          return Scan(elements: elements, isComplete: false)
        }
      }

      elements.append(.assignment(path: path, value: value, first: index, last: last))
      index = last + 1
    }

    return Scan(elements: elements, isComplete: true)
  }

  /// Whether a line can be believed at all.
  ///
  /// A carriage return that survived the split is one TOML does not allow
  /// anywhere: not between statements, not inside a string of any of the four
  /// kinds. Codex cannot parse such a file either, so refusing costs nothing —
  /// and it buys the invariant the rest of this rests on, that every statement
  /// Codex can see is a statement we saw too. Without it a lone `\r` hides the
  /// statement after it from us alone, which is how a record already in the
  /// file gets written a second time.
  private static func isScannable(_ line: Line) -> Bool {
    !line.text.unicodeScalars.contains("\r")
  }

  /// How far through a value the scan is, carried across physical lines.
  ///
  /// The only thing this has to get right is where a value *ends*. A multi-line
  /// string or a nested array can hold a line that begins with `[`, and reading
  /// one of those as a table header is what cleared the scanner's idea of which
  /// table it was in and made it insert a second `trusted_hash` into a table
  /// that already had one.
  private struct ValueScanner {
    private enum Mode {
      case open
      case basicMultiline
      case literalMultiline
    }

    private var mode: Mode = .open
    private var depth = 0

    /// Whether the value has ended.
    var isComplete: Bool { mode == .open && depth == 0 }

    /// Read one physical line. False means the line holds something this
    /// scanner cannot account for, and nothing after it should be believed.
    mutating func consume(_ scalars: [Unicode.Scalar], from start: Int) -> Bool {
      var i = start
      while i < scalars.count {
        switch mode {
        case .basicMultiline:
          if scalars[i] == "\\" {
            i += 2
          } else if CodexTOML.matches(scalars, at: i, "\"\"\"") {
            mode = .open
            i = CodexTOML.skipQuoteRun(scalars, at: i, "\"")
          } else {
            i += 1
          }
        case .literalMultiline:
          if CodexTOML.matches(scalars, at: i, "'''") {
            mode = .open
            i = CodexTOML.skipQuoteRun(scalars, at: i, "'")
          } else {
            i += 1
          }
        case .open:
          switch scalars[i] {
          case "#":
            return true
          case "\"":
            if CodexTOML.matches(scalars, at: i, "\"\"\"") {
              mode = .basicMultiline
              i += 3
            } else {
              guard let end = CodexTOML.basicString(scalars, at: i)?.end else { return false }
              i = end
            }
          case "'":
            if CodexTOML.matches(scalars, at: i, "'''") {
              mode = .literalMultiline
              i += 3
            } else {
              guard let end = CodexTOML.literalString(scalars, at: i)?.end else { return false }
              i = end
            }
          case "[", "{":
            depth += 1
            i += 1
          case "]", "}":
            depth -= 1
            if depth < 0 { return false }
            i += 1
          default:
            i += 1
          }
        }
      }
      return true
    }
  }

  // MARK: - Keys

  /// `[a.b.c]` or `[[a.b.c]]`, whole and unambiguous, or nothing.
  ///
  /// The key is read with TOML's own rules rather than by stopping at the first
  /// `]`, which is what made a path containing a bracket — `we]ird` is a legal
  /// directory name on macOS — produce a table this writer could not read back,
  /// so a second press appended the same table again.
  static func parseHeader(
    _ scalars: [Unicode.Scalar], from start: Int
  ) -> (path: [String], isArray: Bool)? {
    var i = start
    guard i < scalars.count, scalars[i] == "[" else { return nil }
    i += 1
    var isArray = false
    if i < scalars.count, scalars[i] == "[" {
      isArray = true
      i += 1
    }
    guard let path = parseKeyPath(scalars, &i), !path.isEmpty else { return nil }
    guard i < scalars.count, scalars[i] == "]" else { return nil }
    i += 1
    if isArray {
      guard i < scalars.count, scalars[i] == "]" else { return nil }
      i += 1
    }
    skipBlanks(scalars, &i)
    guard i == scalars.count || scalars[i] == "#" else { return nil }
    return (path, isArray)
  }

  /// A dotted key — bare, basic-quoted or literal-quoted parts — from `i`.
  static func parseKeyPath(_ scalars: [Unicode.Scalar], _ i: inout Int) -> [String]? {
    var parts: [String] = []
    while true {
      skipBlanks(scalars, &i)
      guard i < scalars.count else { return nil }
      switch scalars[i] {
      case "\"":
        guard let part = basicString(scalars, at: i) else { return nil }
        parts.append(part.text)
        i = part.end
      case "'":
        guard let part = literalString(scalars, at: i) else { return nil }
        parts.append(part.text)
        i = part.end
      default:
        guard isBareKey(scalars[i]) else { return nil }
        var end = i
        while end < scalars.count, isBareKey(scalars[end]) { end += 1 }
        parts.append(text(scalars[i..<end]))
        i = end
      }
      skipBlanks(scalars, &i)
      guard i < scalars.count, scalars[i] == "." else { return parts }
      i += 1
    }
  }

  // MARK: - Strings

  /// A `"…"` basic string starting at `index`, with its escapes resolved.
  static func basicString(
    _ scalars: [Unicode.Scalar], at index: Int
  ) -> (text: String, end: Int)? {
    var i = index + 1
    var out = String.UnicodeScalarView()
    while i < scalars.count {
      if scalars[i] == "\"" { return (String(out), i + 1) }
      guard scalars[i] == "\\" else {
        out.append(scalars[i])
        i += 1
        continue
      }
      i += 1
      guard i < scalars.count else { return nil }
      switch scalars[i] {
      case "\"": out.append("\"")
      case "\\": out.append("\\")
      case "b": out.append("\u{08}")
      case "f": out.append("\u{0C}")
      case "n": out.append("\n")
      case "r": out.append("\r")
      case "t": out.append("\t")
      case "u", "U":
        let digits = scalars[i] == "u" ? 4 : 8
        guard let decoded = escapedScalar(scalars, at: i + 1, digits: digits) else { return nil }
        out.append(decoded)
        i += digits
      default:
        return nil
      }
      i += 1
    }
    return nil
  }

  /// A `'…'` literal string starting at `index`. No escapes: a Windows path in
  /// a key means exactly what it says.
  static func literalString(
    _ scalars: [Unicode.Scalar], at index: Int
  ) -> (text: String, end: Int)? {
    var i = index + 1
    while i < scalars.count {
      if scalars[i] == "'" { return (text(scalars[(index + 1)..<i]), i + 1) }
      i += 1
    }
    return nil
  }

  /// The string a value holds, if the value is one plain string and nothing
  /// else. Nil for anything else, which reads as "no record here" rather than
  /// as a hash we half-understood.
  static func stringValue(_ raw: String) -> String? {
    let scalars = Array(raw.unicodeScalars)
    var i = 0
    skipBlanks(scalars, &i)
    guard i < scalars.count else { return nil }
    switch scalars[i] {
    case "\"":
      guard !matches(scalars, at: i, "\"\"\"") else { return nil }
      return basicString(scalars, at: i)?.text
    case "'":
      guard !matches(scalars, at: i, "'''") else { return nil }
      return literalString(scalars, at: i)?.text
    default:
      return nil
    }
  }

  /// `value` as a TOML basic string.
  ///
  /// Codex's keys are absolute paths. A quote or a backslash would end the key
  /// early and file the approval against a different entry; a newline — also
  /// legal in a macOS path — cannot appear in a basic string at all, so writing
  /// one raw stops the whole file parsing on the line we just wrote.
  static func quotedString(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\u{08}": out += "\\b"
      case "\t": out += "\\t"
      case "\n": out += "\\n"
      case "\u{0C}": out += "\\f"
      case "\r": out += "\\r"
      default:
        if scalar.value < 0x20 || scalar.value == 0x7F {
          out += String(format: "\\u%04X", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }

  // MARK: - Small things

  /// Spaces, tabs, and a byte-order mark.
  ///
  /// U+FEFF is in neither `CharacterSet.whitespaces` nor TOML's own definition
  /// of whitespace, but Rust's lexer strips one before parsing, so Codex reads
  /// a file that starts with one perfectly well. Skipping it here is what stops
  /// such a file's first table from being invisible to us alone.
  static func skipBlanks(_ scalars: [Unicode.Scalar], _ i: inout Int) {
    while i < scalars.count, scalars[i] == " " || scalars[i] == "\t" || scalars[i] == "\u{FEFF}" {
      i += 1
    }
  }

  static func matches(_ scalars: [Unicode.Scalar], at index: Int, _ needle: String) -> Bool {
    var i = index
    for scalar in needle.unicodeScalars {
      guard i < scalars.count, scalars[i] == scalar else { return false }
      i += 1
    }
    return true
  }

  /// Past a run of quotes closing a multi-line string. TOML lets the content
  /// end with up to two of them, so the delimiter is the last three of the run.
  private static func skipQuoteRun(
    _ scalars: [Unicode.Scalar], at index: Int, _ quote: Unicode.Scalar
  ) -> Int {
    var i = index
    var run = 0
    while i < scalars.count, scalars[i] == quote, run < 5 {
      i += 1
      run += 1
    }
    return i
  }

  private static func escapedScalar(
    _ scalars: [Unicode.Scalar], at index: Int, digits: Int
  ) -> Unicode.Scalar? {
    guard index + digits <= scalars.count else { return nil }
    var value: UInt32 = 0
    for offset in 0..<digits {
      guard let digit = Character(scalars[index + offset]).hexDigitValue else { return nil }
      value = value * 16 + UInt32(digit)
    }
    return Unicode.Scalar(value)
  }

  private static func isBareKey(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
    default: false
    }
  }

  private static func text(_ slice: ArraySlice<Unicode.Scalar>) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: slice)
    return String(view)
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

  /// The timeout Codex hashes, which is not always the one written in the file.
  ///
  /// `normalize_command_hook` resolves the default and then clamps, and the two
  /// clamps are not the same: `timeout_sec.unwrap_or(600).max(1)` for most
  /// events, but `timeout_sec.unwrap_or(1).clamp(1, SESSION_END_MAX_TIMEOUT_SEC)`
  /// — three seconds — for `SessionEnd` and `Interrupt`, both of which run
  /// inside the shutdown budget. Hashing the written number instead reports a
  /// hook Codex is perfectly happy with as `modified`, which is a false
  /// accusation, and then writes a hash Codex will never accept.
  ///
  /// Only reachable for a hand-written `timeout`: Codex's integration leaves
  /// `timeoutMilliseconds` nil, so Vigil's own installs carry no timeout at all.
  static func normalisedTimeoutSeconds(_ timeout: Int, for event: String) -> Int {
    guard event == "SessionEnd" || event == "Interrupt" else { return max(1, timeout) }
    return min(max(1, timeout), 3)
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
  /// A reader for one table rather than a TOML parser, which is still the right
  /// size for the job: this needs `hooks.state` and nothing else. What changed
  /// is that the scanning is `CodexTOML`'s and is shared with `CodexTrustWriter`
  /// — two hand-rolled scanners agreed with each other right up until a CRLF
  /// file, where this one saw no records, said "untrusted", and sent the user
  /// to a writer that then appended a record already in the file.
  ///
  /// Every shape a record can take falls out of one rule: a table header and a
  /// dotted key are the same path written two ways, so the header's path and
  /// the assignment's, concatenated, name the same thing either way. That reads
  /// the standard-table form Codex itself writes, a dotted key under
  /// `[hooks.state]`, an inline table, `[hooks]` with `state."…".trusted_hash`,
  /// and a top-level dotted key, without a branch for each. Anything else is
  /// simply not seen, which `status` reports as `untrusted` rather than as an
  /// accusation — and the writer refuses to append beside it.
  static func trustRecords(inConfigTOML toml: String) -> [String: String] {
    var records: [String: String] = [:]
    var table: [String] = []
    var insideArrayTable = false

    for element in CodexTOML.scan(CodexTOML.lines(of: toml)).elements {
      switch element {
      case .header(let path, _):
        table = path
        insideArrayTable = false
      case .arrayHeader(let path, _):
        // `[[hooks.state]]` is an array of tables, and a record inside one is
        // not addressed by the key we would look it up under.
        table = path
        insideArrayTable = true
      case .assignment(let path, let value, _, _):
        guard !insideArrayTable else { continue }
        let full = table + path
        guard full.count >= 3, full[0] == "hooks", full[1] == "state" else { continue }
        if full.count == 4, full[3] == "trusted_hash" {
          records[full[2]] = CodexTOML.stringValue(value)
        } else if full.count == 3, value.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
          records[full[2]] = inlineTrustedHash(value)
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
              timeoutSeconds: normalisedTimeoutSeconds(timeout, for: event)))
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
  /// That case gets its own `.untrusted`, not a fold into `.outOfDate`, because
  /// the two are fixed by opposite actions: one by re-running Vigil's install,
  /// the other only by the user trusting the hook inside the host. The panel
  /// reads `HookTrustState.explanation(host:)` for the sentence naming which.
  public static func setupState(
    missingEvents: [String],
    expectedEvents: [String],
    retiredEvents: [String] = [],
    trust: HookTrustState = .notRequired
  ) -> HookSetupState {
    if missingEvents.isEmpty {
      // Checked before the retired-event test: a host that will not run our
      // hooks at all is the more urgent of the two, and the only one the user
      // cannot fix from inside Vigil.
      if !trust.isSatisfied { return .untrusted }
      return retiredEvents.isEmpty ? .ready : .outOfDate
    }
    // Hooks left over from a previous version are proof this agent was set up
    // once, whatever else is missing now.
    if !retiredEvents.isEmpty { return .outOfDate }
    if missingEvents.count < expectedEvents.count { return .outOfDate }
    return .notSetUp
  }
}
