import AppKit
import Foundation
import OSLog

/// Installs the privileged clamshell helper by asking macOS for authorization.
///
/// The alternative is telling people to run a script in Terminal, which is both
/// worse and *less* safe: it trains them to paste sudo commands from a README.
/// This shows the system's own authorization dialog, which names the app and
/// requires the user's password.
///
/// A signed build would use `SMAppService` and a real XPC helper instead. That
/// needs a Developer ID, so until then this is the honest route.
@MainActor
enum ClamshellInstaller {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "clamshell-install")

  enum InstallError: LocalizedError {
    case scriptMissing
    case cancelled
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .scriptMissing:
        "Vigil's installer is missing from the app bundle. Reinstall Vigil."
      case .cancelled:
        nil  // The user declined; not something to report back at them.
      case .failed(let message):
        message
      }
    }
  }

  static func install() throws {
    try run(arguments: "")
  }

  static func uninstall() throws {
    try run(arguments: "--uninstall")
  }

  private static func run(arguments: String) throws {
    guard
      let script = Bundle.main.url(forResource: "install-clamshell", withExtension: "sh")
    else { throw InstallError.scriptMissing }

    // Runs as root with no sudo, so the script cannot read SUDO_USER.
    let command = [
      "VIGIL_TARGET_USER=" + shellQuoted(NSUserName()),
      "/bin/bash", shellQuoted(script.path), arguments,
    ].joined(separator: " ")

    let source = "do shell script \(appleScriptQuoted(command)) with administrator privileges"

    var errorInfo: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)

    guard let errorInfo else {
      log.info("clamshell helper installed")
      return
    }

    // -128 is the user dismissing the password dialog. Not a failure.
    let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
    if code == -128 { throw InstallError.cancelled }

    let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
    log.error("clamshell install failed: \(message, privacy: .public)")
    throw InstallError.failed(message)
  }

  // MARK: - Quoting

  /// Single-quote for the shell. The app's own path can contain anything a
  /// folder name can, including a quote.
  private static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Double-quote for AppleScript, which understands only these two escapes.
  private static func appleScriptQuoted(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}
