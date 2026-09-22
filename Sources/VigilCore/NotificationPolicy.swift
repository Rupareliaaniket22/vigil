import Foundation

/// Which state transitions are worth interrupting someone for.
///
/// Pure, so the rules can be tested without a notification centre. The bar is
/// deliberately high: a utility that pings on every routine change gets muted
/// within a day, and then its one genuinely important message is lost too.
public enum NotificationPolicy {

  public enum Event: Sendable, Equatable {
    /// Everything stopped. The thing someone who walked away is waiting for.
    case allAgentsFinished(count: Int)
    /// A guardrail released the hold while work was still running — their run
    /// may not survive, and nothing else would tell them.
    case guardrailStoppedHold(reason: WakeReason)
  }

  /// A snapshot of what matters for deciding whether to speak up.
  public struct State: Sendable, Equatable {
    public let workingCount: Int
    public let isHolding: Bool
    public let reason: WakeReason

    public init(workingCount: Int, isHolding: Bool, reason: WakeReason) {
      self.workingCount = workingCount
      self.isHolding = isHolding
      self.reason = reason
    }
  }

  /// The one event worth sending for this transition, if any.
  public static func event(from previous: State, to current: State) -> Event? {
    // A guardrail cutting in while work continues outranks everything: the
    // user's run is at risk and only we can tell them.
    if previous.isHolding, !current.isHolding, current.workingCount > 0 {
      return .guardrailStoppedHold(reason: current.reason)
    }

    // Work finished. Only when it genuinely went to zero — going from three
    // agents to one is progress, not completion.
    if previous.workingCount > 0, current.workingCount == 0 {
      return .allAgentsFinished(count: previous.workingCount)
    }

    return nil
  }
}
