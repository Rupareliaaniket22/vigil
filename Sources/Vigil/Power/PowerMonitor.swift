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
    // Every judgement here is made by `PowerConditions.reading`, which is pure
    // and tested. This function's whole job is reading the machine.
    PowerConditions.reading(
      battery: internalBattery(),
      isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
      thermalState: ThermalState(rawValue: ProcessInfo.processInfo.thermalState.rawValue)
        ?? .nominal,
      lidIsClosed: lidClosed()
    )
  }

  /// This Mac's own battery, or nil if it hasn't got one.
  ///
  /// Not simply the first power source. `IOPSCopyPowerSourcesList` also lists a
  /// UPS, and on a Mac mini with one plugged in the first entry *is* the UPS —
  /// so the panel showed the UPS's charge as the Mac's own battery, and the
  /// battery floor stood ready to stop a run on a machine that has no battery
  /// to run down.
  private static func internalBattery() -> PowerConditions.BatteryReading? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }

    let descriptions = sources.compactMap {
      IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
    }

    // By type first. Falling back to the transport rather than to "whatever
    // came first" keeps the floor working on a Mac whose vocabulary we haven't
    // seen, while still declining to read a USB or network UPS as a battery:
    // losing a safety guardrail to an unrecognised string is the worse failure.
    let battery =
      descriptions.first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
      ?? descriptions.first { $0[kIOPSTransportTypeKey] as? String == kIOPSInternalType }
    guard let battery else { return nil }

    // Absent means the bay is empty — an older Mac with the battery taken out.
    // `NSNumber` rather than `Bool`: IOKit reports flags as either.
    guard (battery[kIOPSIsPresentKey] as? NSNumber)?.boolValue ?? true else { return nil }

    // Missing keys become an unreadable battery, which `BatteryReading` reads
    // as full. Guessing 100% here as well would hide that from the one place
    // that decides what an unreadable battery means.
    return PowerConditions.BatteryReading(
      currentCapacity: battery[kIOPSCurrentCapacityKey] as? Int ?? -1,
      maxCapacity: battery[kIOPSMaxCapacityKey] as? Int ?? 0,
      isOnACPower: battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
    )
  }
}
