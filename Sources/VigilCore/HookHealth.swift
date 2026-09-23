import Foundation

/// How a session left the live set.
///
/// There are only two ways, and the difference between them is the whole
/// signal: either the host told us the work was over, or it stopped talking and
/// we gave up on it.
public enum SessionEnding: Sendable, Equatable {
  /// The host sent an idle event and the session was still idle when it aged
  /// out. Its vocabulary worked.
  case reportedIdle
  /// The session was still `working` when the staleness window ran out. Nobody
  /// ever said it had finished — the Mac was held awake for the whole window
  /// on the strength of an event that turned out to be the last one.
  case expiredWhileWorking
}

/// Whether a host is still telling us when its work finishes.
///
/// `HookSetupState` watches *our* expected event set drift and has never been
/// able to see the other direction. Twice now a host has changed its own
/// vocabulary underneath a perfectly healthy-looking install: Claude Code's
/// `Stop` went missing, and then `StopFailure` turned out to be a second event
/// for the same thing. Both were silent. Every finished turn held the Mac awake
/// for the full staleness window, the settings file looked immaculate, the
/// panel said "Reporting", and the only way either was ever found was somebody
/// reading a hook trace by hand.
///
/// This is the signal that would have caught them. It watches how sessions
/// *end* rather than what is in the settings file, because a host that has
/// stopped saying "finished" cannot hide from that: every session it owns runs
/// out the clock instead.
///
/// Deliberately a value type driven by an injected clock, like `SessionStore`
/// beside it. Nothing here reads a clock of its own, so every threshold below
/// can be tested at any ratio and any age without waiting for either.
public struct HookHealth: Sendable, Equatable {

  /// One session ending, and when we saw it.
  private struct Record: Sendable, Equatable {
    let ending: SessionEnding
    let at: Timestamp
  }

  /// How many endings per agent to remember.
  ///
  /// Twenty. Large enough that no single ending can swing the verdict, and
  /// small enough that a host fixed by an update stops being accused without
  /// waiting for Vigil to be restarted: from a full window of timeouts it takes
  /// ten healthy endings to cross back under `timeoutShare`, which is an
  /// afternoon rather than a reinstall. Evidence gathered against a version of
  /// a host the user no longer runs is evidence about a program that no longer
  /// exists.
  public var window: Int

  /// How old an ending may be and still count.
  ///
  /// A day. The window above is the main bound; this one exists for the machine
  /// that sees two endings a week, where twenty endings could otherwise reach
  /// back into the spring.
  public var horizon: TimeInterval

  /// How many endings before this is allowed to say anything at all.
  ///
  /// Eight, and the number is a false-alarm budget rather than a taste.
  ///
  /// An agent genuinely killed mid-run expires exactly the way a host with a
  /// broken vocabulary does — a terminal closed with `SIGKILL`, a Mac that
  /// slept with a run in flight, Vigil itself restarted while something was
  /// working. Nothing about one ending tells those apart, which is why a single
  /// occurrence has to mean nothing.
  ///
  /// So budget the honest kills generously at one in five. That is already
  /// pessimistic: every documented way a turn can end has an idle event behind
  /// it, which is precisely why `Interrupt`, `SessionEnd` and `StopFailure` are
  /// in the event lists at all. At eight endings, `timeoutShare` needs five of
  /// them, and the chance of five or more genuine kills out of eight at a
  /// one-in-five rate is about 1%. At a very pessimistic one in four it is
  /// under 3%. That is the cost of this feature, per agent, per window.
  public var minimumEndings: Int

  /// The share of endings that have to be timeouts before we say so.
  ///
  /// More than half.
  ///
  /// A host that has lost an idle event does not lose it intermittently: every
  /// turn that would have ended with it now ends by timeout instead, so the
  /// real share runs at essentially 100% and clears this bar with room to
  /// spare. Half rather than something higher so that losing *one* of several
  /// idle events — which is exactly what `StopFailure` was — still trips it
  /// once that path accounts for most endings.
  ///
  /// Below half it stays quiet on purpose. A third of turns ending by timeout
  /// is genuinely worth fixing, and it is also indistinguishable from someone
  /// who interrupts a lot of runs. This signal only earns its place by being
  /// quiet when it cannot tell.
  public var timeoutShare: Double

  private var records: [AgentKind: [Record]] = [:]

  public init(
    window: Int = 20,
    horizon: TimeInterval = 24 * 60 * 60,
    minimumEndings: Int = 8,
    timeoutShare: Double = 0.5
  ) {
    self.window = window
    self.horizon = horizon
    self.minimumEndings = minimumEndings
    self.timeoutShare = timeoutShare
  }

  // MARK: - Watching

  /// Classify a session that has just been pruned.
  ///
  /// Not the same classification as `AgentSession.outcome`, and deliberately
  /// not shared with it. This one asks whether a *host* is still saying when
  /// its work finishes, so `StopFailure` is a perfectly good ending — the host
  /// spoke — and a session abandoned at a permission prompt is no evidence
  /// either way. `outcome` asks whether the *user's run* finished, where
  /// `StopFailure` means it did not and an abandoned prompt means nobody knows.
  /// Two questions, two answers, and merging them would silently make one of
  /// them wrong.
  ///
  /// Returns nil for a session that was `waiting` when it aged out, and that is
  /// the one judgement call in this file. `waiting` means the host told us it
  /// was blocked on the human and the human never came back; the host spoke, it
  /// simply never got as far as saying the turn was over, because as far as it
  /// is concerned the turn is not over. That says nothing about its idle
  /// vocabulary in either direction — and counting it as a timeout would load
  /// the dice against Claude Code, the only host that reports `waiting` at all.
  public static func ending(of session: AgentSession) -> SessionEnding? {
    switch session.state {
    case .idle: .reportedIdle
    case .working: .expiredWhileWorking
    case .waiting: nil
    }
  }

  /// Record the sessions `SessionStore.prune` just gave up on.
  ///
  /// Sessions rather than turns, because a session ending is the only moment
  /// the answer is unambiguous. It is also enough: a host that has stopped
  /// reporting idle leaves every session it owns `working`, so the next prune
  /// after every stretch of work is a timeout, and the ratio moves at the same
  /// rate the user's work does.
  public mutating func record(expired sessions: [AgentSession], now: Timestamp) {
    for session in sessions {
      guard let ending = Self.ending(of: session) else { continue }
      record(ending, for: session.agent, now: now)
    }
    trim(now: now)
  }

  /// Record one ending directly.
  ///
  /// The classification above is the only thing the app layer needs; this is
  /// for a caller that already knows which of the two it is holding, and for
  /// tests, which have to be able to build a ratio without inventing twenty
  /// sessions to carry it.
  public mutating func record(_ ending: SessionEnding, for agent: AgentKind, now: Timestamp) {
    records[agent, default: []].append(Record(ending: ending, at: now))
    trim(now: now)
  }

  /// Drop what is too old or too far back to count.
  private mutating func trim(now: Timestamp) {
    for (agent, kept) in records {
      let fresh = kept.filter { now.seconds(since: $0.at) <= horizon }.suffix(max(1, window))
      if fresh.isEmpty {
        records.removeValue(forKey: agent)
      } else {
        records[agent] = Array(fresh)
      }
    }
  }

  // MARK: - Reading

  /// What the recent endings for one agent add up to.
  public struct Verdict: Sendable, Equatable {
    /// Endings counted — timeouts plus idle reports, `waiting` excluded.
    public let endings: Int
    /// How many of those ran out the clock.
    public let timeouts: Int
    /// Whether that is enough, and lopsided enough, to be worth saying.
    public let isSuspect: Bool

    /// Zero when nothing has been recorded, which reads as healthy — and is
    /// the right way round: an agent nobody has run is not an agent in trouble.
    public var timeoutShare: Double {
      endings == 0 ? 0 : Double(timeouts) / Double(endings)
    }
  }

  public func verdict(for agent: AgentKind, now: Timestamp) -> Verdict {
    let live = (records[agent] ?? []).filter { now.seconds(since: $0.at) <= horizon }
      .suffix(max(1, window))
    let timeouts = live.filter { $0.ending == .expiredWhileWorking }.count
    let endings = live.count
    let suspect =
      endings >= minimumEndings && Double(timeouts) > Double(endings) * timeoutShare
    return Verdict(endings: endings, timeouts: timeouts, isSuspect: suspect)
  }

  /// Every agent currently worth warning about, in a stable order.
  public func suspectAgents(now: Timestamp) -> [AgentKind] {
    records.keys
      .filter { verdict(for: $0, now: now).isSuspect }
      .sorted { $0.rawValue < $1.rawValue }
  }

  /// What to tell the user, or nil when there is nothing to tell them.
  ///
  /// The wording lives here rather than in the panel for the same reason
  /// `WakeReason`'s does: it is a claim about a host's behaviour, so it belongs
  /// beside the evidence for it and inside the tests. It says "may have
  /// changed" because that is the honest strength of this signal — it is a
  /// ratio over a handful of endings, not a proof, and a sentence that
  /// overstated it would be the same kind of confident wrong answer the rest of
  /// this work is removing.
  public func warning(for agent: AgentKind, now: Timestamp) -> String? {
    guard verdict(for: agent, now: now).isSuspect else { return nil }
    let name = AgentIntegration.displayName(for: agent)
    return "\(name) sessions have been ending by timeout rather than reporting they "
      + "finished — its hooks may have changed."
  }

  /// Whether anything has been recorded at all. Mostly for tests and for a
  /// caller that wants to know the signal is warm before trusting its silence.
  public var isEmpty: Bool { records.isEmpty }
}
