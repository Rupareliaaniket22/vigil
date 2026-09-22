import Foundation
import IOKit.pwr_mgt
import OSLog

/// Holds and releases the macOS power assertion that keeps the Mac awake.
///
/// This needs no privileges and no entitlement — it is the same mechanism
/// `caffeinate` uses. Only lid-closed operation requires elevation, and that
/// lives behind `ClamshellController`.
@MainActor
final class PowerAssertion {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "power")

  private var assertionID: IOPMAssertionID = 0
  private(set) var isHeld = false

  /// Take the assertion, or update its reason if we already hold one.
  ///
  /// `kIOPMAssertionTypePreventUserIdleSystemSleep` keeps the machine running
  /// but lets the display sleep — users want a dark screen overnight while an
  /// agent works.
  func hold(reason: String) {
    guard !isHeld else {
      // Cheapest way to refresh the human-readable reason shown in `pmset -g assertions`.
      IOPMAssertionSetProperty(
        assertionID, kIOPMAssertionNameKey as CFString, reason as CFString)
      return
    }

    var id: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason as CFString,
      &id
    )

    guard result == kIOReturnSuccess else {
      Self.log.error("failed to create power assertion: \(result, privacy: .public)")
      return
    }
    assertionID = id
    isHeld = true
    Self.log.info("holding wake assertion \(id, privacy: .public): \(reason, privacy: .public)")
  }

  func release() {
    guard isHeld else { return }
    let result = IOPMAssertionRelease(assertionID)
    if result != kIOReturnSuccess {
      Self.log.error("failed to release assertion: \(result, privacy: .public)")
    }
    Self.log.info("released wake assertion \(self.assertionID, privacy: .public)")
    assertionID = 0
    isHeld = false
  }

  deinit {
    // Never leave the Mac pinned awake because we went away.
    if isHeld { IOPMAssertionRelease(assertionID) }
  }
}

/// One power assertion held somewhere on the system.
struct SystemAssertion: Identifiable, Sendable {
  let id: String
  let pid: Int32
  let processName: String
  let type: String
  let reason: String

  /// Assertions that actually prevent the system sleeping, as opposed to
  /// display-only or informational ones.
  var preventsSystemSleep: Bool {
    type == kIOPMAssertionTypePreventUserIdleSystemSleep
      || type == kIOPMAssertionTypePreventSystemSleep
  }
}

extension PowerAssertion {
  /// Every assertion currently held on this Mac, by any process.
  ///
  /// This answers "why won't my Mac sleep?" — including when the answer is
  /// something other than us. No competitor surfaces this.
  static func systemAssertions() -> [SystemAssertion] {
    var out: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
      let byProcess = out?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
    else {
      return []
    }

    return byProcess.flatMap { pid, assertions in
      assertions.compactMap { entry -> SystemAssertion? in
        guard let type = entry["AssertType"] as? String else { return nil }
        let name = entry["AssertName"] as? String ?? "—"
        let process = entry["Process Name"] as? String ?? "pid \(pid.int32Value)"
        return SystemAssertion(
          id: "\(pid.int32Value)-\(type)-\(name)",
          pid: pid.int32Value,
          processName: process,
          type: type,
          reason: name
        )
      }
    }
    .sorted { $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending }
  }
}
