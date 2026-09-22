import Foundation
import OSLog

/// Keeping the Mac awake with the lid shut means clearing `SleepDisabled` on
/// IOPMrootDomain, which needs root. There is more than one way to get there,
/// and which one is available depends on how this build was signed — so the
/// mechanism sits behind a protocol and is chosen at launch.
protocol ClamshellBackend: Sendable {
  /// Whether this backend is usable on this machine right now.
  var isAvailable: Bool { get }
  /// Human-readable name, shown in Settings so the user knows what is installed.
  var displayName: String { get }
  func setSleepDisabled(_ disabled: Bool) async throws
}

enum ClamshellError: LocalizedError {
  case notInstalled
  case commandFailed(status: Int32, message: String)

  var errorDescription: String? {
    switch self {
    case .notInstalled:
      "Lid-closed support is not installed. Open Settings → Advanced to set it up."
    case let .commandFailed(status, message):
      "Could not change the lid-close setting (exit \(status)): \(message)"
    }
  }
}

/// Free path: a small root-owned shell script, permitted by a narrowly scoped
/// `/etc/sudoers.d` rule to run exactly two `pmset` argument vectors and nothing
/// else. No wildcards, no shell interpolation — the classic way these rules turn
/// into privilege escalation.
struct SudoersClamshellBackend: ClamshellBackend {
  static let helperPath = "/usr/local/libexec/vigil-clamshell"

  var displayName: String { "sudoers helper" }

  var isAvailable: Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: Self.helperPath, isDirectory: &isDir),
      !isDir.boolValue
    else { return false }
    // Refuse to trust a helper that is not root-owned and not write-protected —
    // a user-writable binary behind a NOPASSWD rule is a root shell.
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.helperPath),
      let owner = attrs[.ownerAccountID] as? NSNumber, owner.intValue == 0,
      let perms = attrs[.posixPermissions] as? NSNumber, perms.int16Value & 0o022 == 0
    else { return false }
    return true
  }

  func setSleepDisabled(_ disabled: Bool) async throws {
    guard isAvailable else { throw ClamshellError.notInstalled }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["-n", Self.helperPath, disabled ? "on" : "off"]

    let errPipe = Pipe()
    process.standardError = errPipe
    process.standardOutput = Pipe()

    try process.run()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw ClamshellError.commandFailed(
        status: process.terminationStatus,
        message: String(decoding: errData, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }
}

/// Paid path (v2): an `SMAppService` daemon reached over XPC.
///
/// Registration is refused unless the app and helper share a Developer ID team,
/// so this backend reports itself unavailable in ad-hoc builds. It fails
/// *silently* at the OS level, which is why `isAvailable` is conservative.
struct XPCClamshellBackend: ClamshellBackend {
  var displayName: String { "privileged helper" }
  var isAvailable: Bool { false }  // TODO(v2): SMAppService registration + XPC client.

  func setSleepDisabled(_: Bool) async throws {
    throw ClamshellError.notInstalled
  }
}

/// Picks the best backend available, preferring the signed helper when present.
@MainActor
final class ClamshellController {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "clamshell")

  private let backends: [any ClamshellBackend]
  private(set) var isDisabled = false

  init(backends: [any ClamshellBackend] = [XPCClamshellBackend(), SudoersClamshellBackend()]) {
    self.backends = backends
  }

  var activeBackend: (any ClamshellBackend)? {
    backends.first(where: \.isAvailable)
  }

  var isSupported: Bool { activeBackend != nil }

  func setSleepDisabled(_ disabled: Bool) async {
    guard isDisabled != disabled else { return }
    guard let backend = activeBackend else {
      Self.log.notice("no clamshell backend available; lid-close will still sleep")
      return
    }
    do {
      try await backend.setSleepDisabled(disabled)
      isDisabled = disabled
      Self.log.info(
        "clamshell sleep \(disabled ? "disabled" : "restored", privacy: .public) via \(backend.displayName, privacy: .public)"
      )
    } catch {
      Self.log.error("clamshell change failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Restore normal sleep. Called on quit and from the watchdog — leaving a
  /// laptop unable to sleep in a bag is the worst failure this app can have.
  func restoreOnExit() {
    guard isDisabled, let backend = activeBackend else { return }
    let sema = DispatchSemaphore(value: 0)
    Task.detached {
      try? await backend.setSleepDisabled(false)
      sema.signal()
    }
    _ = sema.wait(timeout: .now() + 3)
  }
}
