import Foundation
import IOKit.ps
import VigilCore

/// Reads battery and power-source state. Desktops report as permanently on
/// mains at 100%, which makes every guardrail a no-op for them.
enum PowerMonitor {
  static func current() -> PowerConditions {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
      let first = sources.first,
      let description = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue()
        as? [String: Any]
    else {
      return PowerConditions()
    }

    let capacity = description[kIOPSCurrentCapacityKey] as? Int ?? 100
    let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
    let state = description[kIOPSPowerSourceStateKey] as? String

    return PowerConditions(
      batteryPercent: max > 0 ? Int((Double(capacity) / Double(max) * 100).rounded()) : 100,
      isPluggedIn: state == kIOPSACPowerValue,
      isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
      lidIsClosed: nil
    )
  }
}
