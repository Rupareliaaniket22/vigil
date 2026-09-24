import Foundation

/// One thing that went wrong while Vigil was putting an agent's hooks in order.
///
/// Here rather than in the app layer for the reason everything else here is:
/// the rule that decides what the user is told about a failed pass is worth
/// testing, and the pass itself cannot be — it writes to four settings files in
/// somebody's home directory.
public struct SetupFailure: Sendable, Equatable {

  /// The agent it happened to, as the user knows it.
  ///
  /// Carried separately rather than left for the reader to spot inside
  /// `reason`. The installer's sentences name a *path* — `~/.claude/
  /// settings.json`, `~/.gemini/settings.json` — which is the right detail to
  /// have in the sentence and the wrong thing to ask somebody to translate back
  /// into "Claude Code" while they are working out what is broken.
  public let host: String

  /// The installer's own sentence.
  ///
  /// Host-supplied length: it can carry a path, a list of every hook entry in
  /// somebody's settings file, or — through `ClamshellInstaller.failed` — the
  /// untouched output of a script. Nothing here may assume a bound on it, which
  /// is why `summary(of:)` puts the part that has to be read first.
  public let reason: String

  public init(host: String, reason: String) {
    self.host = host
    self.reason = reason
  }
}

extension SetupFailure {

  /// Everything that went wrong in one pass, in one string.
  ///
  /// A maintenance pass touches every agent on the Mac, and it used to report
  /// the last thing that went wrong and nothing else: one slot, written on
  /// every error. Two agents failing in the same pass left the first one's
  /// reason nowhere at all — the user was shown an agent that had plainly not
  /// been set up, and the only way to find out why was to press its own button
  /// and make the same failure happen again. Nobody presses anything on this
  /// path, so nobody is standing by to notice which one they were told about.
  ///
  /// The shape is the one the interface already uses for text Vigil did not
  /// write: the part that has to be read is short and bounded, and the whole of
  /// it is one hover away. So the *names* come first — that is the line the
  /// settings window has room for, and it is the half that was missing — and
  /// the reasons follow, one to a line, for the tooltip and for whatever of
  /// them fits above it. Neither view needs to grow to carry this: the panel
  /// puts the whole string on `.help()` and shows a sentence of its own, and
  /// the settings window caps it at three lines, so four failures at once cost
  /// the same height as one.
  ///
  /// A single failure is spelled exactly as it always was, with no preamble.
  /// Naming one agent twice in two lines is worse copy than the installer's own
  /// sentence, which already says which file it could not write.
  public static func summary(of failures: [SetupFailure]) -> String? {
    guard let only = failures.first else { return nil }
    guard failures.count > 1 else { return only.reason }
    // Each agent named once, in the order it failed. One agent can in principle
    // fail twice in a pass — an install and an approval are two writes — and
    // "Codex and Codex didn't finish" would be the one sentence here that made
    // the reader doubt the rest.
    var hosts: [String] = []
    for failure in failures where !hosts.contains(failure.host) { hosts.append(failure.host) }
    return "\(list(hosts)) didn't finish.\n"
      + failures.map { "\($0.host): \($0.reason)" }.joined(separator: "\n")
  }

  /// "A, B and C", no Oxford comma — the house style everywhere else.
  static func list(_ items: [String]) -> String {
    guard let last = items.last else { return "" }
    guard items.count > 1 else { return last }
    return items.dropLast().joined(separator: ", ") + " and " + last
  }
}
