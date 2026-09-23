import CryptoKit
import Foundation

/// Whether the privileged helper on this Mac is the one this copy of Vigil
/// would install.
///
/// Vigil's wake hold needs no privileges at all. Lid-closed support is the one
/// exception: a small root-owned shell script at
/// `/Library/PrivilegedHelperTools/vigil-clamshell`, reachable without a
/// password through a scoped `sudoers` rule. It is installed once, from the
/// copy inside the app bundle, and then never looked at again — so the app and
/// the privileged thing it drives drift apart the moment one is updated
/// without the other, and nothing notices.
///
/// That is not hypothetical. On the machine this was written on, the installed
/// helper is an older build of the same script: its usage line still says
/// `on|off` from before the third verb existed. The verb itself survived —
/// `sleep` is in the installed `case` statement and works — but only because
/// the argument handling happened not to change in between. Had it gone the
/// other way, Vigil would have been calling `vigil-clamshell sleep` against a
/// helper that answers `exit 64`, and the guardrail that has to *ask* a
/// lid-shut Mac to sleep would have failed in silence. This check exists to
/// make that a visible condition rather than a lucky one.
///
/// What it is deliberately **not** is a tamper check. Writing to
/// `/Library/PrivilegedHelperTools` already requires root, so anyone who could
/// substitute the helper did not need to. Reporting this as tampering would be
/// a frightening claim the evidence cannot support; "installed by a different
/// version" is the whole of what a hash difference means.
public enum HelperIntegrity {

  /// What the comparison found.
  public enum State: Sendable, Equatable {
    /// Lid-closed support has never been set up. Not a problem — the toggle
    /// that turns it on already says so.
    case notInstalled
    /// Byte-for-byte what this copy of Vigil would install.
    case current
    /// Installed, and not what this copy of Vigil would install.
    case outOfDate
    /// We could not compare the two. Says nothing, for the same reason
    /// `HookTrustState.unknown` says nothing: a check that cannot run is not
    /// evidence of a fault.
    case unreadable

    /// What to tell the user, or nil when there is nothing worth saying.
    ///
    /// It names root, because that is the whole reason a cosmetic difference
    /// in a shell script is worth a line of interface at all, and it names the
    /// remedy, because a notice nobody can act on is a nicer way of saying
    /// nothing.
    public var notice: String? {
      switch self {
      case .notInstalled, .current, .unreadable:
        nil
      case .outOfDate:
        "The lid-closed helper on this Mac was installed by a different version "
          + "of Vigil. It runs as root, so rather than assume it still matches, "
          + "reinstall lid-closed support to bring it up to date."
      }
    }

    /// Whether this is worth putting in front of anyone.
    public var needsAttention: Bool { self == .outOfDate }
  }

  /// SHA-256, lowercase hex.
  ///
  /// Compared rather than stored: there is no baked-in expected value to go
  /// stale, because the expected value ships in the same bundle as the code
  /// asking the question.
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Compare the installed helper against the one in the app bundle.
  ///
  /// Both are passed in rather than read here — VigilCore does no I/O, and a
  /// comparison that takes its two arguments is one a test can drive through
  /// every case without a privileged file anywhere near it.
  ///
  /// The bundled copy is the right thing to compare against, not the repository
  /// source: `install-clamshell.sh` installs `clamshell-helper.sh` from its own
  /// directory, and inside the app that directory is `Contents/Resources`. So
  /// these are exactly the bytes this build would put in place if asked to.
  public static func state(installed: Data?, bundled: Data?) -> State {
    guard let installed else { return .notInstalled }
    guard let bundled, !bundled.isEmpty else { return .unreadable }
    return digest(installed) == digest(bundled) ? .current : .outOfDate
  }
}
