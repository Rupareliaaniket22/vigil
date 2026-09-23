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
      "Lid-closed support isn't installed. Open Settings and turn on "
        + "\u{201C}Keep working with the lid closed\u{201D}."
    case .commandFailed(let status, let message):
      "Could not change the lid-close setting (exit \(status)): \(message)"
    }
  }
}

/// Free path: a small root-owned shell script, permitted by a narrowly scoped
/// `/etc/sudoers.d` rule to run exactly three fixed argument vectors — `on`,
/// `off` and `sleep` — and nothing else. No wildcards, no shell interpolation —
/// the classic way these rules turn into privilege escalation.
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

// MARK: - Restoring sleep from a signal handler

// A signal handler runs on whatever thread the signal happened to interrupt,
// at whatever instruction it happened to interrupt. If that thread was inside
// `malloc`, or inside the Objective-C runtime's lock, anything the handler does
// that needs the same lock deadlocks — and this is the handler whose whole job
// is to stop a Mac being left unable to sleep. `sigaction(2)` lists what may be
// called from one, and that list is the rule everything below is measured
// against.
//
// What that rules out is most of Foundation: `FileManager`, `URL` and
// `Process` each allocate and each touch the Objective-C runtime, and the
// previous version of this code called all three.
//
// `fork()` and `execve()` are on the list and would be the obvious shape, but
// Swift's Darwin overlay marks `fork()` unavailable ("Please use threads or
// posix_spawn*()"). `posix_spawn` is the supported spelling on this platform
// and, called the way it is called here — no file actions, no attributes — it
// is a thin wrapper that marshals nothing and allocates nothing before
// trapping into the kernel. (The `posix_spawn` that is *not* safe to call here
// is glibc's, which emulates it with clone/exec in userspace.)

/// The argument vector for `sudo -n <helper> off`, built before any handler
/// exists.
///
/// A `@convention(c)` handler cannot capture, so the handler's inputs have to
/// live in globals. Reading a Swift global runs its one-time initialiser, which
/// takes a lock and may allocate — precisely what must not happen in a signal
/// context — so the ordering in `installSignalHandlers` is load-bearing:
/// `prepareSignalSafeRestore()` runs first and forces all three of these, and
/// only then is a handler armed. There is no window in which a signal can
/// arrive to find one of them half-initialised, because until `sigaction`
/// returns there is no handler to run.
private nonisolated(unsafe) var restoreArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
/// A fixed, minimal environment rather than the process's own. `environ` is a
/// pointer any thread can replace by calling `setenv`, so reading it from a
/// handler means reading an array something else may be halfway through
/// swapping out. `sudo` resets the environment anyway.
private nonisolated(unsafe) var restoreEnvp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
/// The helper's own path, for the existence check. Separate from `restoreArgv`
/// so that reordering the argument vector cannot silently change what is being
/// checked.
private nonisolated(unsafe) var restoreHelperPath: UnsafeMutablePointer<CChar>?

/// Fills the three globals above, exactly once, however many callers race.
///
/// Every line of this allocates, which is the entire reason it happens here
/// rather than in the handler. Nothing is ever freed: it has to outlive any
/// signal that could arrive, which means the life of the process.
private let signalSafeRestoreIsPrepared: Bool = {
  func vector(_ words: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let out = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
      .allocate(capacity: words.count + 1)
    for (index, word) in words.enumerated() { out[index] = strdup(word) }
    out[words.count] = nil  // posix_spawn wants the vector NULL-terminated.
    return out
  }

  restoreHelperPath = strdup(SudoersClamshellBackend.helperPath)
  restoreArgv = vector(["/usr/bin/sudo", "-n", SudoersClamshellBackend.helperPath, "off"])
  restoreEnvp = vector(["PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
  return true
}()

/// Do the allocating half now, so the signal-context half never has to.
private func prepareSignalSafeRestore() {
  _ = signalSafeRestoreIsPrepared
}

/// Clear `SleepDisabled` from a context where almost nothing is safe to call.
///
/// `access` and `waitpid` are on `sigaction(2)`'s list verbatim; `posix_spawn`
/// stands in for the `fork`/`execve` pair that is, for the reason set out
/// above. Nothing else is called at all.
///
/// Requires `prepareSignalSafeRestore()` to have run. Does nothing if it has
/// not, rather than reaching for a lock to fix it.
private func restoreSleepSignalSafely() {
  // sigaction(2): "it is good practice to make a copy of the global variable
  // errno and restore it before returning from the signal handler." The code
  // we interrupted may be between a failing syscall and its own errno check.
  let saved = errno
  defer { errno = saved }

  guard let argv = restoreArgv, let envp = restoreEnvp, let helper = restoreHelperPath
  else { return }

  // `access` is on the safe list; `FileManager.isExecutableFile`, which this
  // replaces, is not. Checked here rather than once at launch because the user
  // can install the helper from Settings hours after the app started.
  guard access(helper, X_OK) == 0 else { return }

  var child: pid_t = 0
  guard posix_spawn(&child, argv[0], nil, nil, argv, envp) == 0 else { return }

  // Wait for it. The point of running at all is that the flag is actually
  // clear before we let the signal through and die; spawning `sudo` and
  // immediately exiting would leave the race this exists to close.
  var status: Int32 = 0
  while waitpid(child, &status, 0) < 0 && errno == EINTR {}
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
  /// The handler runs in a signal context, where almost nothing is safe to
  /// call, so everything it needs is worked out here first — see the notes
  /// above `restoreArgv`. Priming before `sigaction`, never after, is the part
  /// that makes the handler safe rather than merely smaller.
  nonisolated func installSignalHandlers() {
    prepareSignalSafeRestore()

    let restore: @convention(c) (Int32) -> Void = { signal in
      restoreSleepSignalSafely()
      // Put the default disposition back and let the signal through, so the
      // process still dies exactly as it would have. `signal()` and `raise()`
      // are both on sigaction(2)'s safe list. The signal is blocked while we
      // are in here, so it lands the moment this returns.
      Foundation.signal(signal, SIG_DFL)
      raise(signal)
    }

    let handled = [SIGINT, SIGTERM, SIGHUP]

    // `sigaction` rather than `signal`, only so the mask can be stated: a
    // Ctrl-C that also hangs up the terminal would otherwise deliver two of
    // these at once and run the handler nested inside itself.
    var mask = sigset_t()
    sigemptyset(&mask)
    for sig in handled { sigaddset(&mask, sig) }

    for sig in handled {
      var action = sigaction()
      action.__sigaction_u = __sigaction_u(__sa_handler: restore)
      action.sa_mask = mask
      action.sa_flags = 0
      sigaction(sig, &action, nil)
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
    // Ask the system, not only what we last believed. `apply` reconciles
    // against `IOPMrootDomain` rather than trusting our own last write, and
    // quit is the one moment that has to be at least as careful: a worker that
    // has already spawned `sudo … on` has not written `isDisabled` yet, and
    // macOS moves this flag underneath us regardless. Gating on the cached
    // answer alone left the flag set on exactly the path SECURITY.md calls the
    // primary one, while the signal handler — which never asks, and simply
    // clears it — got it right. Reading is unprivileged and costs nothing; a
    // laptop that cannot sleep in a bag costs a battery and a hot chassis.
    guard isDisabled || SleepDisabledFlag.current() == true else { return }
    // Synchronous and direct, the same path the signal handler takes. Quit is
    // not a moment to hand work to a task and block the main thread waiting on
    // a semaphore — and the process may not outlive the await.
    Self.restoreSynchronously()
    isDisabled = false
  }

  /// Restore normal sleep with a blocking call and no concurrency machinery.
  ///
  /// The same implementation the signal handlers use, deliberately: quit and a
  /// SIGTERM are the same job, and two implementations of it would mean the
  /// one that runs less often is the one that rots. Off the signal path there
  /// is no harm in the setup being allocating, so this door primes the storage
  /// on the way through — `stop()` can reach here on a run where `start()`
  /// never did.
  nonisolated static func restoreSynchronously() {
    prepareSignalSafeRestore()
    restoreSleepSignalSafely()
  }
}
