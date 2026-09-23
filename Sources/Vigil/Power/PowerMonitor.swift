import Foundation
import IOKit.ps
import VigilCore

/// Reads battery and power-source state. Desktops report as permanently on
/// mains at 100%, which makes every guardrail a no-op for them.
enum PowerMonitor {

  /// Whether the lid is shut. Nil on machines without one.
  ///
  /// Matters because asking the Mac to sleep is only safe when nobody is
  /// looking at it. `AppleClamshellState` is readable without privileges.
  static func lidClosed() -> Bool? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }

    let property = IORegistryEntryCreateCFProperty(
      service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()

    switch property {
    case let closed as Bool: return closed
    case let number as NSNumber: return number.boolValue
    default: return nil  // Desktops don't publish it at all.
    }
  }
  static func current() -> PowerConditions {
    let thermal = ThermalState(rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .nominal

    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
      let first = sources.first,
      let description = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue()
        as? [String: Any]
    else {
      // No battery: a desktop. Every power guardrail is a no-op for it, but
      // heat is not — a Mac mini under a desk can still cook.
      return PowerConditions(
        thermalState: thermal, lidIsClosed: lidClosed(), hasBattery: false)
    }

    let capacity = description[kIOPSCurrentCapacityKey] as? Int ?? 100
    let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
    let state = description[kIOPSPowerSourceStateKey] as? String

    return PowerConditions(
      batteryPercent: max > 0 ? Int((Double(capacity) / Double(max) * 100).rounded()) : 100,
      isPluggedIn: state == kIOPSACPowerValue,
      isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
      thermalState: thermal,
      lidIsClosed: lidClosed(),
      hasBattery: true
    )
  }
}
