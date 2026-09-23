import Foundation

/// A moment read from two clocks at once.
///
/// `Date` is wall-clock time. NTP can step it backwards — a laptop that has
/// been asleep for a week does exactly this within seconds of waking — and when
/// it does, an elapsed time computed from it goes negative. A `.working`
/// session whose age never passes the staleness window is immortal, and an
/// immortal session holds the Mac awake forever: the one failure this app
/// exists to prevent.
///
/// So every elapsed-time decision reads `uptime`, which only ever increases,
/// cannot be adjusted, and keeps counting while the Mac is asleep. `wall` is
/// kept alongside it for display, where showing the user their own clock is the
/// whole point.
public struct Timestamp: Sendable, Equatable {
  /// For display. Never for deciding whether something has expired.
  public let wall: Date
  /// For elapsed time. Monotonic, so a clock adjustment cannot rewind it.
  public let uptime: ContinuousClock.Instant

  public init(wall: Date, uptime: ContinuousClock.Instant) {
    self.wall = wall
    self.uptime = uptime
  }

  /// Both clocks, read together.
  public static var now: Timestamp {
    Timestamp(wall: Date(), uptime: ContinuousClock.now)
  }

  /// Seconds from `earlier` to here, measured monotonically.
  ///
  /// Clamped at zero: two timestamps taken in either order still answer "how
  /// long ago" with something a duration format can render.
  public func seconds(since earlier: Timestamp) -> TimeInterval {
    max(0, earlier.uptime.duration(to: uptime).seconds)
  }

  /// A timestamp this far ahead on both clocks. Lets a test move time without
  /// waiting for it.
  public func advanced(by seconds: TimeInterval) -> Timestamp {
    Timestamp(
      wall: wall.addingTimeInterval(seconds),
      uptime: uptime.advanced(by: .seconds(seconds))
    )
  }
}

extension Duration {
  /// `Duration` as a plain number of seconds.
  var seconds: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
  }
}
