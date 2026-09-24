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

/// Whether Vigil keeps agent hooks in order by itself, and what it remembers
/// about the decisions the user has already made.
///
/// Deliberately not a field on `WakeSettings`, for the reason `SoundSettings`
/// is not one: that value is the input to `WakePolicy`, and whether Vigil edits
/// a settings file has no business being an argument to a decision about power.
/// Same `UserDefaults` and the same `object(forKey:)` reading, so that "never
/// set" stays distinguishable from "set to off" — somebody who turned this off
/// must not find it back on after the next launch.
///
/// The two remembered sets are not settings, and neither is a permission. One
/// is a record of a decision the user made, kept because the files themselves
/// cannot hold it: a settings file with none of Vigil's hooks in it looks
/// identical before the first install and after a removal, so removal has to be
/// remembered or it does not stick. The other is a record of a decision *Vigil*
/// made, kept so the interface can say it out loud — nothing consults it before
/// acting, and its only reader is the settings row.
enum HookManagement {

  /// Named once. The switch in the settings window binds straight to
  /// `UserDefaults` through `@AppStorage`, so there is exactly one key and no
  /// second copy of the value to fall out of step with this one.
  static let managesKey = "managesAgentHooks"

  /// On.
  ///
  /// Installing hooks is the whole of what this app does to be useful, and an
  /// agent that is not wired up is an agent Vigil cannot see. Off is for
  /// somebody who wants to decide each time, and it restores exactly the
  /// ask-first behaviour Vigil had before: every state that could be fixed
  /// automatically becomes a button instead.
  static let managesByDefault = true

  static var manages: Bool {
    UserDefaults.standard.object(forKey: managesKey) as? Bool ?? managesByDefault
  }

  /// Agents Vigil has written hooks for on this Mac, ever.
  ///
  /// Never cleared, including by a removal — that is the whole point. See
  /// `HookMaintenance.action` for why this is the signal that makes removal
  /// stick and what it deliberately cannot tell apart.
  private static let setUpKey = "agentsVigilHasSetUp"

  /// Hosts whose trust record Vigil has written for itself.
  ///
  /// Not a permission and not consulted before writing one — `HookMaintenance
  /// .action` decides that, and the byte-for-byte comparison in
  /// `CodexTrustWriter.selfWrittenRecords` is what bounds it. This exists so
  /// the settings row can *say so afterwards*, which is the whole difference
  /// between doing something automatically and doing it secretly.
  ///
  /// Never cleared either. A host Vigil has approved for is one Vigil has
  /// approved for, and the row goes on saying it — including after the user
  /// turns automatic management off, because the record is still in their
  /// `config.toml` and they are entitled to know how it got there.
  private static let selfTrustedKey = "agentsVigilHasTrusted"

  static func hasBeenSetUp(_ agent: AgentKind) -> Bool { contains(agent, in: setUpKey) }
  static func rememberSetUp(_ agent: AgentKind) { remember(agent, in: setUpKey) }

  static func hasBeenSelfTrusted(_ agent: AgentKind) -> Bool {
    contains(agent, in: selfTrustedKey)
  }
  static func rememberSelfTrusted(_ agent: AgentKind) { remember(agent, in: selfTrustedKey) }

  /// Stored as a sorted array of raw values: `UserDefaults` holds no sets, and
  /// a stable order keeps a plist diff readable for anyone who looks.
  private static func contains(_ agent: AgentKind, in key: String) -> Bool {
    (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(agent.rawValue)
  }

  private static func remember(_ agent: AgentKind, in key: String) {
    var stored = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    guard stored.insert(agent.rawValue).inserted else { return }
    UserDefaults.standard.set(stored.sorted(), forKey: key)
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
