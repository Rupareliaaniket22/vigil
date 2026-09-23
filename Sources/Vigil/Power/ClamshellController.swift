import Foundation
import IOKit
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
  /// `requestSleep` asks the Mac to sleep immediately as well as restoring the
  /// flag. Needed when a guardrail fires with the lid shut: macOS only
  /// re-evaluates clamshell sleep on a lid event, so clearing the flag alone
  /// leaves the machine awake and draining.
  func setSleepDisabled(_ disabled: Bool, requestSleep: Bool) async throws
}

enum ClamshellError: LocalizedError {
  case notInstalled
  case commandFailed(status: Int32, message: String)

  var errorDescription: String? {
    switch self {
    case .notInstalled:
      "Lid-closed support is not installed. Open Settings → Advanced to set it up."
    case .commandFailed(let status, let message):
      "Could not change the lid-close setting (exit \(status)): \(message)"
    }
  }
}

/// Free path: a small root-owned shell script, permitted by a narrowly scoped
/// `/etc/sudoers.d` rule to run exactly two `pmset` argument vectors and nothing
/// else. No wildcards, no shell interpolation — the classic way these rules turn
/// into privilege escalation.
struct SudoersClamshellBackend: ClamshellBackend {
  static let helperPath = "/Library/PrivilegedHelperTools/vigil-clamshell"

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

  func setSleepDisabled(_ disabled: Bool, requestSleep: Bool) async throws {
    guard isAvailable else { throw ClamshellError.notInstalled }

    let verb = disabled ? "on" : (requestSleep ? "sleep" : "off")
    // `sudo` can take a moment, and blocking a cooperative-pool thread for it
    // would stall unrelated async work — the socket bridge included.
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", Self.helperPath, verb]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
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
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
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

  func setSleepDisabled(_: Bool, requestSleep _: Bool) async throws {
    throw ClamshellError.notInstalled
  }
}

/// Reads `SleepDisabled` from `IOPMrootDomain`.
///
/// Reading needs no privileges — only writing does. This is what makes it
/// possible to detect drift rather than trusting what we last set.
enum SleepDisabledFlag {
  static func current() -> Bool? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }

    let property = IORegistryEntryCreateCFProperty(
      service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()

    // The registry reports this as a number on some systems and a boolean on
    // others; accept either rather than silently returning nil.
    switch property {
    case let flag as Bool: return flag
    case let number as NSNumber: return number.boolValue
    default: return nil
    }
  }
}

/// Picks the best backend available, preferring the signed helper when present.
@MainActor
final class ClamshellController {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "clamshell")

  private let backends: [any ClamshellBackend]
  private(set) var isDisabled = false

  /// The state we want the system to be in. Set by every evaluation; applied by
  /// a single worker.
  private var desired: (disabled: Bool, requestSleep: Bool)?
  /// Nil when no work is in flight.
  private var worker: Task<Void, Never>?

  init(backends: [any ClamshellBackend] = [XPCClamshellBackend(), SudoersClamshellBackend()]) {
    self.backends = backends
  }

  /// Put sleep back the way we found it, at launch.
  ///
  /// `applicationWillTerminate` does not run on a crash, a force-quit, or a
  /// kill. If Vigil died with lid-close sleep disabled, the Mac stays unable to
  /// sleep with nothing left running to undo it — a laptop that cooks in a bag
  /// is the worst thing this app can do. Clearing the flag on every launch
  /// closes the case where the user relaunches; `installSignalHandlers` covers
  /// termination signals.
  func restoreOnLaunch() async {
    guard let backend = activeBackend else { return }
    do {
      try await backend.setSleepDisabled(false, requestSleep: false)
      isDisabled = false
      Self.log.info("restored normal sleep at launch")
    } catch {
      Self.log.notice(
        "could not restore sleep at launch: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Restore on the signals that skip `applicationWillTerminate`.
  ///
  /// The handler runs in a signal context, so it does the smallest possible
  /// thing: shell out to the helper synchronously, then re-raise with the
  /// default disposition so the process still dies as expected.
  nonisolated func installSignalHandlers() {
    let restore: @convention(c) (Int32) -> Void = { signal in
      ClamshellController.restoreSynchronously()
      Foundation.signal(signal, SIG_DFL)
      raise(signal)
    }

    for sig in [SIGINT, SIGTERM, SIGHUP] {
      Foundation.signal(sig, restore)
    }
  }

  var activeBackend: (any ClamshellBackend)? {
    backends.first(where: \.isAvailable)
  }

  var isSupported: Bool { activeBackend != nil }

  /// Record what the system should be doing, and make sure exactly one worker
  /// is driving it there.
  ///
  /// Calls arrive on every five-second tick *and* on every hook event, and each
  /// one shells out to `sudo`. Spawning a task per call let two overlap: the
  /// second evaluated `isDisabled` before the first had written it, skipped the
  /// change as redundant, and left the flag set after a guardrail had fired —
  /// the precise "laptop cooks in a bag" outcome the battery floor exists to
  /// prevent. One worker, latest-wins.
  func setSleepDisabled(_ disabled: Bool, requestSleep: Bool = false) {
    desired = (disabled, requestSleep)
    guard worker == nil else { return }
    worker = Task { [weak self] in
      await self?.drain()
      self?.worker = nil
    }
  }

  private func drain() async {
    while let target = desired {
      desired = nil
      await apply(target.disabled, requestSleep: target.requestSleep)
    }
  }

  private func apply(_ disabled: Bool, requestSleep: Bool) async {
    // Reconcile against the system rather than a cached belief. macOS can clear
    // this flag underneath us — a power-source change is the case other
    // implementations keep filing bugs about — and trusting our own last write
    // means never noticing. Reading is unprivileged, so this is cheap.
    if let actual = SleepDisabledFlag.current() {
      if actual != isDisabled {
        Self.log.notice(
          "clamshell flag drifted: we believed \(self.isDisabled, privacy: .public), system says \(actual, privacy: .public)"
        )
      }
      isDisabled = actual
    }

    // An immediate sleep request must still go through even when the flag is
    // already where we want it — that is the whole point of the `sleep` verb.
    guard isDisabled != disabled || requestSleep else { return }
    guard let backend = activeBackend else {
      Self.log.notice("no clamshell backend available; lid-close will still sleep")
      return
    }
    do {
      try await backend.setSleepDisabled(disabled, requestSleep: requestSleep)
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
    guard isDisabled else { return }
    // Synchronous and direct, the same path the signal handler takes. Quit is
    // not a moment to hand work to a task and block the main thread waiting on
    // a semaphore — and the process may not outlive the await.
    Self.restoreSynchronously()
    isDisabled = false
  }

  /// Restore normal sleep with a blocking call and no concurrency machinery.
  ///
  /// Shared by the quit path and the signal handlers, which run in a context
  /// where almost nothing else is safe to do.
  nonisolated static func restoreSynchronously() {
    let helper = SudoersClamshellBackend.helperPath
    guard FileManager.default.isExecutableFile(atPath: helper) else { return }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["-n", helper, "off"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }
}
