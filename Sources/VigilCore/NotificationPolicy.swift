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
    /// Work started with a guardrail already in force, so no hold was ever
    /// taken. Nothing transitioned, which is exactly why this has to be its
    /// own case: the rule above watches a hold end, and here one never began.
    case guardrailPreventedHold(reason: WakeReason)
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
    //
    // `isGuardrail` is half the test, not a restatement of the other half. A
    // pause drops the hold with agents still working too, and without this the
    // one alert the app sends at time-sensitive priority, with a sound, fired
    // to report something the user had chosen from this app's own menu a
    // second earlier — and told them their run "may not finish" as if it had
    // happened to them. That is the notification that gets an app muted, and
    // the guardrail warning is then lost along with it.
    if previous.isHolding, !current.isHolding, current.workingCount > 0,
      current.reason.isGuardrail
    {
      return .guardrailStoppedHold(reason: current.reason)
    }

    // The guardrail that was already in force when the work arrived. Battery
    // at 12%, someone starts a run and walks away: no hold is taken, no hold
    // ends, so the rule above never sees it and the app says nothing at all
    // about the one thing it exists to do. That silence is worse than the
    // interruption — they find out when they come back to a sleeping Mac.
    //
    // `previous.workingCount == 0` makes this strictly the moment work begins,
    // so it fires once rather than on every five-second tick for as long as
    // the battery stays low; and `!previous.isHolding` keeps it disjoint from
    // the rule above, which owns every case where a hold actually ended.
    if !previous.isHolding, !current.isHolding, previous.workingCount == 0,
      current.workingCount > 0, current.reason.isGuardrail
    {
      return .guardrailPreventedHold(reason: current.reason)
    }

    // Work finished. Only when it genuinely went to zero — going from three
    // agents to one is progress, not completion.
    if previous.workingCount > 0, current.workingCount == 0 {
      return .allAgentsFinished(count: previous.workingCount)
    }

    return nil
  }

  /// The "why" half of a status line, for copy that has already said the "what".
  ///
  /// The guardrail alert is handed a whole status line — "Your Mac can sleep —
  /// Battery 18%, below the 20% you set" — and its title has already said that
  /// the hold stopped. Pasting the line in whole spends the first half of the
  /// one sentence anyone reads on a lock screen restating the title, and does
  /// it in words that read as a contradiction of it.
  ///
  /// Splits on the first separator only: one reason — "On battery — you chose
  /// mains power only" — contains a second, and it is the half worth keeping.
  /// Anything with no separator at all is already a detail, and comes back
  /// untouched.
  public static func detail(inStatusLine line: String) -> String {
    guard let separator = line.range(of: " \u{2014} ") else { return line }
    return String(line[separator.upperBound...])
  }
}
