import Foundation
import ServiceManagement
import VigilCore

/// Persistence for `WakeSettings`.
///
/// Plain `UserDefaults` rather than a wrapper library: there are four values,
/// and the popular typed-defaults package pulls in swift-syntax, which is
/// punishingly slow to compile on a Command Line Tools toolchain.
enum SettingsStore {
  private enum Key {
    static let batteryFloor = "batteryFloorPercent"
    static let onlyWhenPluggedIn = "onlyWhenPluggedIn"
    static let respectLowPowerMode = "respectLowPowerMode"
    static let allowClamshell = "allowClamshell"
    static let thermalCeiling = "thermalCeiling"
  }

  static func load() -> WakeSettings {
    let defaults = UserDefaults.standard
    let fallback = WakeSettings()

    return WakeSettings(
      // `object(forKey:)` distinguishes "never set" from "set to zero"; a user
      // who deliberately chose a 0% floor must not be reset to 20 on relaunch.
      batteryFloorPercent: defaults.object(forKey: Key.batteryFloor) as? Int
        ?? fallback.batteryFloorPercent,
      onlyWhenPluggedIn: defaults.object(forKey: Key.onlyWhenPluggedIn) as? Bool
        ?? fallback.onlyWhenPluggedIn,
      respectLowPowerMode: defaults.object(forKey: Key.respectLowPowerMode) as? Bool
        ?? fallback.respectLowPowerMode,
      allowClamshell: defaults.object(forKey: Key.allowClamshell) as? Bool
        ?? fallback.allowClamshell,
      thermalCeiling: (defaults.object(forKey: Key.thermalCeiling) as? Int)
        .flatMap(ThermalState.init(rawValue:)) ?? fallback.thermalCeiling
    )
  }

  static func save(_ settings: WakeSettings) {
    let defaults = UserDefaults.standard
    defaults.set(settings.batteryFloorPercent, forKey: Key.batteryFloor)
    defaults.set(settings.onlyWhenPluggedIn, forKey: Key.onlyWhenPluggedIn)
    defaults.set(settings.respectLowPowerMode, forKey: Key.respectLowPowerMode)
    defaults.set(settings.allowClamshell, forKey: Key.allowClamshell)
    defaults.set(settings.thermalCeiling.rawValue, forKey: Key.thermalCeiling)
  }
}

/// Whether Vigil makes a sound when a run finishes.
///
/// Deliberately not a field on `WakeSettings`: that value is the input to
/// `WakePolicy`, and whether the Mac makes a noise has no business being an
/// argument to a decision about power. Same `UserDefaults` and the same
/// `object(forKey:)` reading as above, for the same reason — "never set" has
/// to stay distinguishable from "set to off", or somebody who turned the sound
/// off would find it back on after the next launch.
enum SoundSettings {
  /// Named once. The switch in the settings window binds straight to
  /// `UserDefaults` through `@AppStorage`, so there is exactly one key and no
  /// second copy of the value to fall out of step with this one.
  static let completionSoundKey = "playsCompletionSound"

  /// On.
  ///
  /// The sound is the thing that was asked for, and a run that finishes in
  /// silence is the feature not existing until somebody goes looking for a
  /// switch. It is also a bounded sort of loud: the chime rides on a
  /// notification, so Focus, Do Not Disturb and a notification permission that
  /// was never granted each silence it without anyone touching this — and
  /// turning it off restores exactly the silent, banner-less notification
  /// Vigil sent before there was a sound at all.
  static let playsCompletionSoundByDefault = true

  static var playsCompletionSound: Bool {
    UserDefaults.standard.object(forKey: completionSoundKey) as? Bool
      ?? playsCompletionSoundByDefault
  }
}

/// Launch at login, via `SMAppService`.
///
/// Read `status` fresh every time rather than caching: the user can toggle this
/// in System Settings behind our back, and a stale switch is worse than none.
enum LoginItem {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  static func set(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}
