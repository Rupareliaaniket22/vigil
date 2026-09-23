import Foundation

/// A host program's version, as its publisher numbers it.
///
/// Not a general SemVer implementation, and deliberately less than one. The
/// only question asked of it is "is this copy older than the release that grew
/// a hook subsystem", so it resolves the numeric release line and stops.
public struct HostVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
  /// The dotted numbers, most significant first. Missing trailing components
  /// compare as zero, so `0.19` and `0.19.0` are the same release.
  public let components: [Int]

  /// What the host called it, kept verbatim for the sentence shown to the user.
  ///
  /// Printing our own reassembly would quietly disagree with what `--version`
  /// says on the very machine the notice is about, which is the fastest way to
  /// make a true claim look wrong.
  public let text: String

  public var description: String { text }

  /// Parse a version out of whatever a host wrote down.
  ///
  /// Accepts a leading `v`, and stops at the first thing that is not a number
  /// or a dot — so `0.19.0-preview.1` and `0.19.0+build7` both resolve to
  /// `0.19.0`.
  ///
  /// Treating a pre-release as equal to its release is the one judgement call
  /// here, and it is made in the direction of not accusing. SemVer orders
  /// `0.19.0-preview.1` *below* `0.19.0`, which would put a preview build one
  /// notch under a floor of `0.19.0` and report it as too old. But a preview is
  /// cut from the same branch as the release it precedes — Gemini CLI's
  /// `v0.19.0-preview.1` and `v0.19.0` were published within an hour of each
  /// other and carry the same hook subsystem — so the strict reading would be
  /// wrong about the only thing this type is asked. A floor is a question about
  /// which release line a copy belongs to, and that is what this answers.
  public init?(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var body = Substring(trimmed)
    if body.first == "v" || body.first == "V" { body = body.dropFirst() }

    let numeric = body.prefix { $0.isNumber || $0 == "." }
    let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
    var components: [Int] = []
    for part in parts {
      guard let value = Int(part) else { break }
      components.append(value)
    }
    // A bare number is a version — Cursor ships `3.21.18`, but a host that
    // called itself `4` would still be answerable. Nothing at all is not.
    guard !components.isEmpty else { return nil }

    self.components = components
    self.text = trimmed
  }

  /// A version written down rather than parsed, for the floors recorded in
  /// `AgentIntegration`.
  ///
  /// Three numbers and no optional, because a floor is a constant in this
  /// source and a constant that can fail to parse is a constant that can be
  /// nil on somebody's Mac and nowhere else.
  public init(_ major: Int, _ minor: Int, _ patch: Int) {
    self.components = [major, minor, patch]
    self.text = "\(major).\(minor).\(patch)"
  }

  public static func < (lhs: HostVersion, rhs: HostVersion) -> Bool {
    let width = max(lhs.components.count, rhs.components.count)
    for index in 0..<width {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  /// Equality on the release line, not on the text.
  ///
  /// `0.19` and `0.19.0` are one release written two ways, and a floor that
  /// said otherwise would refuse a copy that is plainly new enough.
  public static func == (lhs: HostVersion, rhs: HostVersion) -> Bool {
    !(lhs < rhs) && !(rhs < lhs)
  }
}

/// The release at which a host became able to run a hook at all, and the
/// command to look for to find out which release is installed.
///
/// One field rather than two, because neither half is any use alone: a name to
/// search for with no floor to compare against answers nothing, and a floor
/// with nothing to look for cannot be applied. Recorded on the integration the
/// way every other difference between hosts is — see `AgentIntegration` — so
/// the next host to grow a hook subsystem is one field rather than a branch.
public struct HookFloor: Sendable, Equatable {
  /// What this host is called when it is installed as a command.
  public let executable: String
  /// The first release that can run a hook at all.
  public let since: HostVersion

  public init(executable: String, since: HostVersion) {
    self.executable = executable
    self.since = since
  }
}

/// One copy of a host's command that Vigil found, and what it could date it to.
public struct HostCopy: Sendable, Equatable {
  /// Where it was found, spelled the way the user will be shown it.
  public let path: String
  /// The version its install layout declared, or nil when the layout declared
  /// none. Vigil never runs the command to ask — see `HostProbe`.
  public let version: HostVersion?

  public init(path: String, version: HostVersion?) {
    self.path = path
    self.version = version
  }
}

/// Whether the host on this Mac could run the hooks Vigil installed for it.
///
/// A different question again from "are our hooks in the file" and "will the
/// host honour them", and the most dangerous of the three to answer, because
/// the evidence is so much weaker than it looks. Vigil cannot see how anyone
/// launches their agent. It runs from a GUI bundle, so it does not have the
/// user's shell environment; people run agents through `npx`, `bunx`, `mise`,
/// `asdf`, a nix shell, a project-local `node_modules/.bin`, a shell alias or
/// a wrapper script, none of which leaves a trace Vigil can read; and the same
/// Mac can hold several copies at different versions with only the user's own
/// `PATH` order deciding which one runs.
///
/// So this type is built to be quiet. There is exactly one shape it will call
/// a problem — every copy Vigil could find is below the floor, which means no
/// reading of this Mac has a copy that could fire the hook — and every other
/// shape, absence included, reads as satisfied. `HookTrustState.unknown` takes
/// the same position for the same reason: a check that could not run is a
/// reason to say nothing, never a reason to accuse a working install.
public enum HostHookSupport: Sendable, Equatable {
  /// No floor is recorded for this host, so there is nothing to compare
  /// against. The state every integration but Gemini CLI is in today.
  case notChecked
  /// Vigil looked where it is able to look and found no copy.
  ///
  /// Deliberately **not** a problem, and this is the case the whole design
  /// turns on. Vigil searches a written-down list of install locations; it
  /// cannot search the user's `PATH`, because a Vigil opened from Finder or by
  /// a login item inherits launchd's — `/usr/bin:/bin:/usr/sbin:/sbin`, which
  /// holds none of the places an agent is ever installed — while one started
  /// from a terminal inherits that terminal's, which holds all of them. "Not
  /// installed", said confidently about a tool somebody runs every day, is
  /// worse than saying nothing at all.
  case notFound
  /// Copies were found and none of them carried a version.
  ///
  /// A shim, a wrapper script, a single-file binary: all perfectly healthy
  /// installs whose layout simply does not write a version down. Nothing to
  /// report.
  case undated
  /// At least one copy Vigil found is at or above the floor.
  case supported
  /// Every copy Vigil found is below the floor.
  ///
  /// The only shape worth a word, and the claim is safe whatever the user's
  /// `PATH` order is: there is no copy here that could run the hook, so the
  /// hooks Vigil wrote into this host's settings are inert.
  case tooOld(copies: [HostCopy], needs: HostVersion)

  /// Whether the hooks Vigil installed can fire.
  ///
  /// Everything but `tooOld` counts as usable, on purpose: see above.
  public var isUsable: Bool {
    switch self {
    case .notChecked, .notFound, .undated, .supported: true
    case .tooOld: false
    }
  }

  /// The versions Vigil dated, oldest first. Empty unless it found old copies.
  public var foundVersions: [HostVersion] {
    guard case .tooOld(let copies, _) = self else { return [] }
    return copies.compactMap(\.version).sorted()
  }

  /// What to tell the user, or nil when there is nothing to tell them.
  ///
  /// Written here rather than in the interface for the same reason
  /// `HookTrustState.explanation(host:)` is: it is a claim about another
  /// program, so it belongs beside the rule that establishes it and inside the
  /// tests.
  ///
  /// Every clause is hedged to exactly the strength of the evidence. "Vigil can
  /// see" rather than "you have", because the search is a written list and not
  /// the user's `PATH`. The version and the floor are both named, because a
  /// user who does run a newer copy needs enough in the sentence to tell that
  /// Vigil is looking at the wrong one. And the instruction is to update the
  /// host, which is the only thing that resolves it and is not something Vigil
  /// can do.
  public func explanation(host: String) -> String? {
    guard case .tooOld(let copies, let needs) = self else { return nil }
    let versions = copies.compactMap(\.version).sorted()
    guard let oldest = versions.first else { return nil }

    // The floor leads, because it is the fact, and the copies follow, because
    // they are the evidence for it. The other way round put "older than that"
    // in front of the number it referred to.
    let found =
      versions.count == 1
      ? "the copy Vigil can see is \(oldest)"
      : "every copy Vigil can see is older — \(Self.list(versions.map(\.text)))"
    return
      "\(host) grew hooks in \(needs), and \(found). The hooks Vigil installed "
      + "will not fire until you update it."
  }

  /// The panel's shorter half of the same sentence.
  ///
  /// DESIGN.md keeps version numbers and another program's release history off
  /// the panel, so the numbers go on the hover with `explanation(host:)` and
  /// this says the part that is worth a row. It keeps "can find", because the
  /// hedge is the claim: what Vigil established is that nothing it can see
  /// would run the hook, not that nothing on the Mac would.
  public func panelNote(host: String) -> String? {
    guard case .tooOld = self else { return nil }
    // No action on the end, unlike the trust note beside it, and the absence is
    // the honest part: the trust note can say "Trust them in Settings" because
    // a button in Settings does exactly that, and there is no button anywhere
    // in Vigil that updates somebody's agent. The hook-health note is the same
    // shape for the same reason.
    return "Every copy of \(host) Vigil can find is too old to run hooks."
  }

  /// "A, B and C", no Oxford comma — the house style everywhere else.
  private static func list(_ items: [String]) -> String {
    guard let last = items.last else { return "" }
    guard items.count > 1 else { return last }
    return items.dropLast().joined(separator: ", ") + " and " + last
  }
}

/// Reaching a verdict from the copies a search turned up.
///
/// Pure, so the rule that decides whether Vigil says anything at all is
/// testable without a filesystem. `HostProbe` does the looking; this does the
/// judging, and the judging is where the false accusation would be.
extension HostHookSupport {
  /// What a set of found copies means, given a floor.
  ///
  /// The rule, stated once: **a single copy at or above the floor buys the
  /// whole Mac silence.** A machine holding both an ancient copy and a current
  /// one is a machine where the user plausibly runs the current one, and Vigil
  /// has no way to tell which — so it says nothing, exactly as it does when it
  /// cannot read a trust file. That is deliberately the quiet mistake: the loud
  /// one would put a permanent notice in front of somebody whose agent works
  /// perfectly, about a stale symlink they have not touched in a year.
  ///
  /// What is left is the case where the claim cannot be wrong. Every copy
  /// below the floor means there is no copy here that could fire the hook,
  /// whatever the user's `PATH` order resolves to — and then Vigil is not
  /// guessing, it is reporting.
  public static func verdict(copies: [HostCopy], floor: HookFloor?) -> HostHookSupport {
    guard let floor else { return .notChecked }
    guard !copies.isEmpty else { return .notFound }

    let dated = copies.filter { $0.version != nil }
    guard !dated.isEmpty else { return .undated }
    // An undated copy is a copy that might be anything, so it counts as a
    // reason to stay quiet rather than as one more vote for "too old".
    guard dated.count == copies.count else { return .supported }

    let old = dated.filter { ($0.version ?? floor.since) < floor.since }
    guard old.count == dated.count else { return .supported }
    return .tooOld(copies: old, needs: floor.since)
  }
}
