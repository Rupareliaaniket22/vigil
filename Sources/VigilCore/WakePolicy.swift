import Foundation

/// How hot the machine is, as macOS reports it.
///
/// Mirrors `ProcessInfo.ThermalState` so `VigilCore` stays free of Foundation
/// platform types and the policy can be tested at every level without one.
public enum ThermalState: Int, Sendable, Equatable, Comparable, CaseIterable {
  case nominal = 0
  case fair = 1
  case serious = 2
  case critical = 3

  public static func < (a: ThermalState, b: ThermalState) -> Bool {
    a.rawValue < b.rawValue
  }
}

/// Live power state, sampled from IOKit by the app layer.
public struct PowerConditions: Sendable, Equatable {
  public var batteryPercent: Int
  public var isPluggedIn: Bool
  public var isLowPowerMode: Bool
  public var thermalState: ThermalState
  /// Nil on desktops. Clamshell rules only apply to laptops.
  public var lidIsClosed: Bool?

  public init(
    batteryPercent: Int = 100,
    isPluggedIn: Bool = true,
    isLowPowerMode: Bool = false,
    thermalState: ThermalState = .nominal,
    lidIsClosed: Bool? = nil
  ) {
    self.batteryPercent = batteryPercent
    self.isPluggedIn = isPluggedIn
    self.isLowPowerMode = isLowPowerMode
    self.thermalState = thermalState
    self.lidIsClosed = lidIsClosed
  }
}

/// User-configurable rules.
public struct WakeSettings: Sendable, Equatable {
  /// Stop holding the Mac awake below this charge. The single most important
  /// guardrail: a Mac held awake in a bag will flatten its battery and cook.
  public var batteryFloorPercent: Int
  /// Refuse to hold the Mac awake on battery at all.
  public var onlyWhenPluggedIn: Bool
  /// Treat macOS Low Power Mode as a request to stay out of the way.
  public var respectLowPowerMode: Bool
  /// Whether the user wants lid-closed operation (needs elevated privileges).
  public var allowClamshell: Bool
  /// Release the hold at or above this thermal state.
  ///
  /// `.serious` by default, not `.critical`: by the time macOS says critical it
  /// is already throttling hard, and a machine held awake inside a closed bag
  /// has nowhere to dump the heat.
  public var thermalCeiling: ThermalState

  public init(
    batteryFloorPercent: Int = 20,
    onlyWhenPluggedIn: Bool = false,
    respectLowPowerMode: Bool = true,
    allowClamshell: Bool = false,
    thermalCeiling: ThermalState = .serious
  ) {
    self.batteryFloorPercent = batteryFloorPercent
    self.onlyWhenPluggedIn = onlyWhenPluggedIn
    self.respectLowPowerMode = respectLowPowerMode
    self.allowClamshell = allowClamshell
    self.thermalCeiling = thermalCeiling
  }
}

/// Why the Mac is (or is not) being held awake. Surfaced verbatim in the UI —
/// users should never have to guess.
public enum WakeReason: Sendable, Equatable {
  case agentsWorking(count: Int)
  case manualOverride
  case paused(until: Date)
  case noAgents
  case batteryBelowFloor(percent: Int, floor: Int)
  case onBatteryAndPluggedInRequired
  case lowPowerMode
  case tooHot(state: ThermalState)

  public var holdsWake: Bool {
    switch self {
    case .agentsWorking, .manualOverride: true
    case .paused, .noAgents, .batteryBelowFloor, .onBatteryAndPluggedInRequired, .lowPowerMode,
      .tooHot:
      false
    }
  }
}

public struct WakeDecision: Sendable, Equatable {
  public let holdIdleAssertion: Bool
  public let disableClamshellSleep: Bool
  public let reason: WakeReason

  public init(holdIdleAssertion: Bool, disableClamshellSleep: Bool, reason: WakeReason) {
    self.holdIdleAssertion = holdIdleAssertion
    self.disableClamshellSleep = disableClamshellSleep
    self.reason = reason
  }
}

public enum WakePolicy {
  /// Decide whether to hold the Mac awake.
  ///
  /// Guardrails are evaluated before intent: no amount of agent activity or
  /// manual override beats a flat battery.
  public static func decide(
    sessions: [AgentSession],
    conditions: PowerConditions,
    settings: WakeSettings,
    manualOverride: Bool = false,
    pausedUntil: Date? = nil,
    now: Date = Date()
  ) -> WakeDecision {
    func decision(_ reason: WakeReason) -> WakeDecision {
      let hold = reason.holdsWake
      return WakeDecision(
        holdIdleAssertion: hold,
        // Clamshell is strictly an escalation of an idle hold, never independent.
        disableClamshellSleep: hold && settings.allowClamshell,
        reason: reason
      )
    }

    // --- Guardrails first. These override everything. ---

    // Heat outranks even the battery rules, and applies on mains power too: a
    // plugged-in Mac held awake in a closed bag is the hottest case there is.
    if conditions.thermalState >= settings.thermalCeiling {
      return decision(.tooHot(state: conditions.thermalState))
    }

    if !conditions.isPluggedIn {
      if settings.onlyWhenPluggedIn {
        return decision(.onBatteryAndPluggedInRequired)
      }
      if conditions.batteryPercent < settings.batteryFloorPercent {
        return decision(
          .batteryBelowFloor(
            percent: conditions.batteryPercent, floor: settings.batteryFloorPercent)
        )
      }
      if settings.respectLowPowerMode && conditions.isLowPowerMode {
        return decision(.lowPowerMode)
      }
    }

    if let until = pausedUntil, until > now {
      return decision(.paused(until: until))
    }

    // --- Intent. ---
    if manualOverride { return decision(.manualOverride) }

    let working = sessions.filter { $0.state == .working }
    // `.waiting` deliberately does not hold the Mac awake: an agent blocked on a
    // permission prompt may sit there for hours, and the user is away.
    if !working.isEmpty { return decision(.agentsWorking(count: working.count)) }

    return decision(.noAgents)
  }
}
