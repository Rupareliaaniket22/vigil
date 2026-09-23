import Foundation
import OSLog
import VigilCore

/// Reads the two copies of the privileged helper so `HelperIntegrity` can
/// compare them.
///
/// Belongs beside `ClamshellController` in `Power/`, and sits here only because
/// of how the change that introduced it was split up. Moving it is a rename.
///
/// Cached, and that is the point of the type rather than an optimisation.
/// `AppModel.reevaluate` runs every five seconds for the life of the app, and
/// hashing two files on every tick to answer a question whose answer can only
/// change when the user installs something would be exactly the kind of idle
/// work a power utility has no business doing. Computed once, and again only
/// when something has been installed.
@MainActor
enum HelperDrift {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "helper")

  private static var cached: HelperIntegrity.State?

  /// Where the installer puts the helper.
  ///
  /// The same path `SudoersClamshellBackend.helperPath` invokes and
  /// `install-clamshell.sh` writes, spelled a third time because neither is
  /// reachable from here — the backend is internal to `Power/` and the script
  /// is a script. A second copy of a constant is a thing that can drift, and
  /// the drift would be quiet: this would simply start answering
  /// `notInstalled` and the notice would never appear again. Folding it into
  /// one constant is the right fix and wants the two to live together.
  static let installedPath = "/Library/PrivilegedHelperTools/vigil-clamshell"

  /// Whether the installed helper is the one this build ships.
  static var state: HelperIntegrity.State {
    if let cached { return cached }
    let state = measure()
    cached = state
    if state == .outOfDate {
      // Logged as well as surfaced. A root-owned file differing from the app
      // that drives it is worth a line in the system log even on a machine
      // where nobody opens the panel.
      log.notice("installed clamshell helper differs from the bundled one")
    }
    return state
  }

  /// One line for the panel, or nil when there is nothing to say.
  static var notice: String? { state.notice }

  /// Throw the cached answer away. Called after anything that installs or
  /// removes the helper, so the notice clears itself without a restart.
  static func invalidate() { cached = nil }

  private static func measure() -> HelperIntegrity.State {
    // `nil` and "could not be read" are different answers, and the difference
    // decides between saying nothing and accusing a healthy install. An absent
    // file is lid-closed support that was never set up; a present file we
    // cannot read is a check that could not run.
    let installed: Data?
    if FileManager.default.fileExists(atPath: installedPath) {
      guard let data = FileManager.default.contents(atPath: installedPath) else {
        return .unreadable
      }
      installed = data
    } else {
      installed = nil
    }

    let bundled = Bundle.main.url(forResource: "clamshell-helper", withExtension: "sh")
      .flatMap { try? Data(contentsOf: $0) }

    return HelperIntegrity.state(installed: installed, bundled: bundled)
  }
}
