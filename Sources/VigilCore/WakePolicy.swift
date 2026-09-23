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

  /// Whether this Mac has a battery at all.
  ///
  /// No policy reads it — a desktop reports as permanently on mains at 100%,
  /// which already makes every power guardrail a no-op. It exists because
  /// "100%, on mains" and "there is no battery" are the same numbers, and the
  /// panel has to tell them apart: a meter reading a full charge forever is a
  /// decoration on a Mac mini, and the status line is the one line in the app
  /// that cannot afford a decoration.
  public var hasBattery: Bool

  public init(
    batteryPercent: Int = 100,
    isPluggedIn: Bool = true,
    isLowPowerMode: Bool = false,
    thermalState: ThermalState = .nominal,
    lidIsClosed: Bool? = nil,
    hasBattery: Bool = true
  ) {
    self.batteryPercent = batteryPercent
    self.isPluggedIn = isPluggedIn
    self.isLowPowerMode = isLowPowerMode
    self.thermalState = thermalState
    self.lidIsClosed = lidIsClosed
    self.hasBattery = hasBattery
  }
}

extension PowerConditions {

  /// What the Mac's own battery reports, in the units IOKit reports it in.
  ///
  /// Kept as the raw pair rather than a percentage so the arithmetic — and
  /// every way it can go wrong — lands here, where it can be tested, instead of
  /// in the IOKit call that cannot be.
  public struct BatteryReading: Sendable, Equatable {
    public var currentCapacity: Int
    public var maxCapacity: Int
    public var isOnACPower: Bool

    public init(currentCapacity: Int, maxCapacity: Int, isOnACPower: Bool) {
      self.currentCapacity = currentCapacity
      self.maxCapacity = maxCapacity
      self.isOnACPower = isOnACPower
    }

    /// Charge as a percentage, 0–100.
    ///
    /// An unreadable battery reads as full, deliberately. A maximum capacity of
    /// zero is the SMC not having answered yet, not a flat battery, and taking
    /// it at face value would fire the floor guardrail and stop every run on a
    /// machine that is very likely fully charged. The opposite mistake costs
    /// one evaluation: five seconds later the reading is real and the guardrail
    /// fires on a number worth believing.
    public var percent: Int {
      guard maxCapacity > 0, currentCapacity >= 0 else { return 100 }
      let raw = (Double(currentCapacity) / Double(maxCapacity) * 100).rounded()
      // Clamped before converting, not after: hardware has reported a capacity
      // above its own maximum, and `Int(_:)` on a large enough Double traps.
      return Int(min(100, max(0, raw)))
    }
  }

  /// Assemble the conditions the policy reads from what the machine reports.
  ///
  /// Separate from the IOKit call that feeds it because the interesting cases
  /// are the ones a laptop cannot be put into: a desktop with no battery at
  /// all, a battery that is absent or unreadable, a capacity the SMC has not
  /// filled in yet.
  public static func reading(
    battery: BatteryReading?,
    isLowPowerMode: Bool = false,
    thermalState: ThermalState = .nominal,
    lidIsClosed: Bool? = nil
  ) -> PowerConditions {
    guard let battery else {
      // No battery: a desktop. It is on mains by definition — the wall socket
      // is the only thing keeping it running — so every power guardrail is a
      // no-op for it. Heat is not: a Mac mini under a desk can still cook, and
      // Low Power Mode is a setting desktops have too.
      return PowerConditions(
        batteryPercent: 100,
        isPluggedIn: true,
        isLowPowerMode: isLowPowerMode,
        thermalState: thermalState,
        lidIsClosed: lidIsClosed,
        hasBattery: false
      )
    }
    return PowerConditions(
      batteryPercent: battery.percent,
      isPluggedIn: battery.isOnACPower,
      isLowPowerMode: isLowPowerMode,
      thermalState: thermalState,
      lidIsClosed: lidIsClosed,
      hasBattery: true
    )
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

  /// Whether a safety rule forced this, as opposed to there simply being no
  /// work. The difference matters: a guardrail firing with the lid shut means
  /// the Mac must be actively told to sleep, or it sits there draining.
  public var isGuardrail: Bool {
    switch self {
    case .batteryBelowFloor, .onBatteryAndPluggedInRequired, .lowPowerMode, .tooHot: true
    case .agentsWorking, .manualOverride, .paused, .noAgents: false
    }
  }

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

  /// Whether a guardrail is the only thing standing between this and a
  /// lid-closed hold — that is, whether we *would* be keeping this Mac awake
  /// with the lid shut had the rule not fired.
  ///
  /// The difference between a guardrail applying and a guardrail stopping
  /// something. A battery below its floor with no agents running and nothing
  /// overridden is a rule that has nothing to undo: whatever is keeping that
  /// Mac awake with its lid shut, it is not us.
  public let clamshellHoldStoppedByGuardrail: Bool

  public init(
    holdIdleAssertion: Bool,
    disableClamshellSleep: Bool,
    reason: WakeReason,
    clamshellHoldStoppedByGuardrail: Bool = false
  ) {
    self.holdIdleAssertion = holdIdleAssertion
    self.disableClamshellSleep = disableClamshellSleep
    self.reason = reason
    self.clamshellHoldStoppedByGuardrail = clamshellHoldStoppedByGuardrail
  }
}

public enum WakePolicy {

  /// Whether to ask the Mac to sleep right now, rather than merely permitting it.
  ///
  /// Needed because macOS only re-evaluates clamshell sleep on a lid event: with
  /// the lid already shut, clearing `SleepDisabled` leaves the machine awake
  /// with nothing asking it to stop, and it keeps draining.
  ///
  /// Gated on the lid actually being closed. With it open the user is sitting in
  /// front of the machine, and sleeping it mid-keystroke reads as a crash.
  ///
  /// And gated on our having been the reason it was awake. `pmset sleepnow`
  /// sleeps a Mac whatever it is doing, and a closed lid does not mean nobody
  /// is at it: a laptop on a stand driving an external display has its lid shut
  /// all day. Asking on `reason.isGuardrail` alone meant that someone working
  /// that way, below their battery floor or on a hot afternoon, had their Mac
  /// put to sleep every five seconds by an app that was holding nothing and had
  /// no hold to undo. The rule is not "a guardrail applies" — it is "a guardrail
  /// took away the lid-closed hold we would otherwise have on this machine".
  public static func shouldRequestImmediateSleep(
    decision: WakeDecision,
    conditions: PowerConditions
  ) -> Bool {
    guard conditions.lidIsClosed == true else { return false }
    guard !decision.disableClamshellSleep else { return false }
    return decision.clamshellHoldStoppedByGuardrail
  }
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
    // What is being asked for, worked out before any safety rule gets a say.
    // Guardrails still win — they are applied first, below — but a guardrail
    // that overrides nothing is not the same event as one that cuts a running
    // hold off, and only this tells them apart.
    let working = sessions.filter { $0.state == .working }.count
    let isPaused = pausedUntil.map { $0 > now } ?? false
    let wouldHold = !isPaused && (manualOverride || working > 0)

    func decision(_ reason: WakeReason) -> WakeDecision {
      let hold = reason.holdsWake
      return WakeDecision(
        holdIdleAssertion: hold,
        // Clamshell is strictly an escalation of an idle hold, never independent.
        disableClamshellSleep: hold && settings.allowClamshell,
        reason: reason,
        clamshellHoldStoppedByGuardrail: reason.isGuardrail && wouldHold
          && settings.allowClamshell
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

    if isPaused, let until = pausedUntil {
      return decision(.paused(until: until))
    }

    // --- Intent. ---
    if manualOverride { return decision(.manualOverride) }

    // `.waiting` deliberately does not hold the Mac awake: an agent blocked on a
    // permission prompt may sit there for hours, and the user is away.
    if working > 0 { return decision(.agentsWorking(count: working)) }

    return decision(.noAgents)
  }
}
