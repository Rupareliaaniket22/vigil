import Foundation

/// Which state transitions are worth interrupting someone for.
///
/// Pure, so the rules can be tested without a notification centre. The bar is
/// deliberately high: a utility that pings on every routine change gets muted
/// within a day, and then its one genuinely important message is lost too.
///
/// The hard question here is what "the run finished" means, and it is not
/// "nothing is working". A session drops out of `working` when it stops to ask
/// the user a question, when its host reports that the turn ended in an error,
/// and when Vigil gives up on a session that went quiet — none of which is a
/// finished run, and one of which happens on every permission prompt. So a run
/// is live while any session is `working` *or* `waiting`, it ends when that set
/// empties, and how it ended is carried in `SessionOutcome` rather than assumed.
public enum NotificationPolicy {

  public enum Event: Sendable, Equatable {
    /// Everything stopped, and every session that stopped said it had finished.
    /// The thing someone who walked away is waiting for.
    case allAgentsFinished(count: Int)
    /// Everything stopped, and at least one session stopped without finishing —
    /// an API error, a context overflow, an escape key. The run is over and the
    /// work is not done, which is the opposite of what a chime would say.
    case runEndedBadly(count: Int)
    /// Everything stopped because Vigil gave up waiting for it. Nobody reported
    /// anything: the host crashed, the terminal closed, the Mac slept. The one
    /// honest thing left to say is that we do not know.
    case lostContact(count: Int)
    /// A guardrail released the hold while work was still running — their run
    /// may not survive, and nothing else would tell them.
    case guardrailStoppedHold(reason: WakeReason)
    /// Work started with a guardrail already in force, so no hold was ever
    /// taken. Nothing transitioned, which is exactly why this has to be its
    /// own case: the rule above watches a hold end, and here one never began.
    case guardrailPreventedHold(reason: WakeReason)

    /// Which of the five this is, with the details taken off.
    public var announcement: Announcement {
      switch self {
      case .allAgentsFinished: .allAgentsFinished
      case .runEndedBadly: .runEndedBadly
      case .lostContact: .lostContact
      case .guardrailStoppedHold: .guardrailStoppedHold
      case .guardrailPreventedHold: .guardrailPreventedHold
      }
    }
  }

  /// An `Event` without its details — the part the sound depends on.
  ///
  /// `Event` carries the `WakeReason` a guardrail fired on, and by the time
  /// one reaches the notification centre the app layer has already rendered
  /// that reason into a sentence, so it holds a `String` and could not rebuild
  /// an `Event` if it wanted to. Stating the sound rule over this instead
  /// leaves one rule, reachable from both sides, with neither side inventing a
  /// `WakeReason` it does not have.
  public enum Announcement: Sendable, Equatable, CaseIterable {
    case allAgentsFinished
    case runEndedBadly
    case lostContact
    case guardrailStoppedHold
    case guardrailPreventedHold

    /// Whether this is a guardrail speaking. Both of them are: one for a hold
    /// that ended, one for a hold that never began.
    public var isGuardrail: Bool {
      switch self {
      case .allAgentsFinished, .runEndedBadly, .lostContact: false
      case .guardrailStoppedHold, .guardrailPreventedHold: true
      }
    }

    /// Whether this is Vigil reporting that a run is over, however it ended.
    ///
    /// The three of them share a sound rule and a switch, because they answer
    /// the same question for the person who walked away — is it over, and can I
    /// stop waiting — and differ only in what the answer is.
    public var endsARun: Bool {
      switch self {
      case .allAgentsFinished, .runEndedBadly, .lostContact: true
      case .guardrailStoppedHold, .guardrailPreventedHold: false
      }
    }
  }

  /// What an announcement should sound like, if anything.
  public enum Sound: Sendable, Equatable {
    /// A run finished. The one sound in this app that exists to be enjoyed, and
    /// the only one that may ever follow `allAgentsFinished`.
    case completion
    /// Something the user has to know about: a guardrail cutting a run short,
    /// or a run that ended without finishing. Deliberately not the same sound,
    /// and not a pleasant one — the chime is a promise that the work is there
    /// when they get back, and these are the cases where it is not.
    case warning
  }

  /// Which guardrail, with its numbers taken off.
  ///
  /// `WakeReason` carries a percentage and a thermal level, so a battery
  /// sitting on its floor produces a different `WakeReason` every few seconds
  /// while being, to anyone reading a notification, the same event happening
  /// over and over. This is the identity the repeat-suppression rule compares.
  public enum GuardrailKind: Sendable, Equatable, CaseIterable {
    case battery
    case mainsOnly
    case lowPower
    case heat

    /// Nil when the reason is not a guardrail at all. Mirrors
    /// `WakeReason.isGuardrail`, and `NotificationPolicyTests` fails if the two
    /// ever disagree about which reasons those are.
    public init?(_ reason: WakeReason) {
      switch reason {
      case .batteryBelowFloor: self = .battery
      case .onBatteryAndPluggedInRequired: self = .mainsOnly
      case .lowPowerMode: self = .lowPower
      case .tooHot: self = .heat
      case .agentsWorking, .manualOverride, .paused, .noAgents: return nil
      }
    }
  }

  /// A snapshot of what matters for deciding whether to speak up.
  public struct State: Sendable, Equatable {
    /// Sessions making progress. The wake decision's question.
    public let workingCount: Int
    /// Sessions stopped on a question for the human. Not working, and not
    /// finished either: the run is mid-sentence.
    public let waitingCount: Int
    public let isHolding: Bool
    public let reason: WakeReason
    /// The worst thing that has happened to a session in this run so far, which
    /// is what the run's own outcome will be if it ends here. `.finished` until
    /// something goes wrong, so a run in perfect health carries the value that
    /// reads as perfect health.
    public let outcome: SessionOutcome
    /// Whether a guardrail has stood between this run and a hold at any point
    /// during it — the hold it lost, or the hold it never got.
    ///
    /// A condition rather than a history of what Vigil has already said. The
    /// version of this rule that asked "was the last announcement a guardrail"
    /// had a hole big enough to walk through: pause the app, let the battery
    /// fall below its floor during the pause, and the guardrail is in force
    /// having announced nothing, because no hold ever ended. The run then dies
    /// of the battery floor and gets congratulated for it.
    public let cutShort: Bool

    /// Sessions that are part of a run in flight.
    public var liveCount: Int { workingCount + waitingCount }

    public init(
      workingCount: Int,
      waitingCount: Int = 0,
      isHolding: Bool,
      reason: WakeReason,
      outcome: SessionOutcome = .finished,
      cutShort: Bool = false
    ) {
      self.workingCount = workingCount
      self.waitingCount = waitingCount
      self.isHolding = isHolding
      self.reason = reason
      self.outcome = outcome
      self.cutShort = cutShort
    }
  }

  /// The one event worth sending for this transition, if any.
  ///
  /// Guardrails first, then the run ending. The two halves are also reachable
  /// on their own, because `Watch` asks them different questions: a guardrail
  /// is a fact about the Mac and is judged once for the whole machine, while a
  /// run ending is a fact about one host's sessions and is judged per host.
  public static func event(from previous: State, to current: State) -> Event? {
    guardrailEvent(from: previous, to: current) ?? runEndEvent(from: previous, to: current)
  }

  /// The guardrail half: a hold a guardrail took away, or never allowed.
  public static func guardrailEvent(from previous: State, to current: State) -> Event? {
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
    //
    // `workingCount`, not `liveCount`, in both guardrail rules below: Vigil
    // never holds the Mac awake for a session that is waiting on its user, so
    // a guardrail takes nothing away from one.
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
    // `previous.liveCount == 0` makes this strictly the moment a *run* begins,
    // so it fires once rather than on every five-second tick for as long as
    // the battery stays low; and `!previous.isHolding` keeps it disjoint from
    // the rule above, which owns every case where a hold actually ended.
    //
    // `liveCount` on the left and `workingCount` on the right, and the two are
    // not interchangeable. This read `previous.workingCount == 0`, which is the
    // same mistake the completion chime made one rule over: `waiting` is not
    // `working`, so an agent stopping to ask permission empties `workingCount`
    // without ending the run, and the `PostToolUse` that follows the approval
    // put it back — which read as work beginning again and raised the alarm all
    // over again. Somebody approving five prompts under a battery floor got
    // five time-sensitive alerts, at the one interruption level a Focus does
    // not silence. The right-hand side stays `workingCount` for the reason
    // above: a run that is only waiting has no hold to be denied yet.
    //
    // What that costs, stated rather than left to be discovered: a run whose
    // very first tick is a `waiting` one — Vigil launched while an agent was
    // already sitting at a prompt — is live before it is ever working, so the
    // approval that starts the work finds `previous.liveCount` at one and says
    // nothing. Telling that case apart from an approval mid-run needs memory of
    // whether this run has ever been working, and buying it would put the
    // repeated alarm back for everyone to catch a case that needs Vigil to have
    // started inside somebody else's prompt.
    if !previous.isHolding, !current.isHolding, previous.liveCount == 0,
      current.workingCount > 0, current.reason.isGuardrail
    {
      return .guardrailPreventedHold(reason: current.reason)
    }

    return nil
  }

  /// The other half: a run that has finished, however it finished.
  public static func runEndEvent(from previous: State, to current: State) -> Event? {
    // The run is over. `liveCount`, not `workingCount`, and that is the whole
    // repair: an agent that stops to ask permission leaves `working` without
    // leaving the run, and counting it as finished announced that the Mac could
    // sleep while the agent sat at the prompt — once per approval, plus once
    // more for the real ending.
    //
    // Which of the three it is comes from what the sessions actually did, not
    // from the count reaching zero. Going from three agents to one is progress
    // either way, so neither of them is an event.
    if previous.liveCount > 0, current.liveCount == 0 {
      switch current.outcome {
      case .finished: return .allAgentsFinished(count: previous.liveCount)
      case .endedBadly: return .runEndedBadly(count: previous.liveCount)
      case .lostContact: return .lostContact(count: previous.liveCount)
      }
    }

    return nil
  }

  /// The sound an announcement carries, if any.
  ///
  /// A separate function rather than something folded into `event(from:to:)`,
  /// and that is the whole of why three agents finishing within a few seconds
  /// of each other make one sound: there is at most one event per transition,
  /// and a sound is a function of an event. Nothing here counts agents, and
  /// nothing here has a timer.
  ///
  /// `cutShort` is the run's own condition — whether a guardrail stood between
  /// it and a hold at any point — rather than the last thing Vigil happened to
  /// say. A run a guardrail killed still ends with every agent stopping, so the
  /// rules above see it end like any other, and making a noise there is the app
  /// saying "over" in the tone it uses for "done" about a run it warned a minute
  /// earlier might not finish. It costs the chime on a run that was cut short
  /// and then recovered, and that is the right way round: a sound that lies is
  /// worse than one that is missing, and that user has already been told their
  /// run was in trouble. It costs nothing after that — `cutShort` is cleared
  /// when the run ends, so the next run is judged on its own conditions.
  public static func sound(
    for announcement: Announcement,
    cutShort: Bool,
    completionSoundEnabled: Bool
  ) -> Sound? {
    switch announcement {
    case .allAgentsFinished:
      guard completionSoundEnabled, !cutShort else { return nil }
      return .completion

    case .runEndedBadly, .lostContact:
      // A sound, because the person this feature is for is in another room and
      // the banner is no use to them — and never the chime, because the chime
      // means the work is waiting for them and here it is not. Gated on the
      // same switch as the chime: it is still a noise at the end of a run, and
      // somebody who turned those off turned off this one too.
      guard completionSoundEnabled, !cutShort else { return nil }
      return .warning

    case .guardrailStoppedHold:
      // Not gated on the setting, and never the completion sound. The setting
      // turns off a chime somebody may not want; this is the alert that says
      // their work is at risk, and it has sounded since before there was a
      // chime for it to be confused with.
      return .warning

    case .guardrailPreventedHold:
      // Silent, as it was before this function existed. It fires the instant
      // work begins, with the person still at the keyboard, and a sound there
      // reads as an error chime for having pressed return.
      return nil
    }
  }

  /// What Vigil has to say about one tick, and what it sounds like.
  public struct Spoken: Sendable, Equatable {
    public let event: Event
    public let sound: Sound?

    public init(event: Event, sound: Sound?) {
      self.event = event
      self.sound = sound
    }

    public var announcement: Announcement { event.announcement }
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

extension NotificationPolicy {

  /// Everything the rules need to remember between ticks, in one place.
  ///
  /// It used to be in two, in the app layer, and that is where the bugs lived:
  /// `AppModel` kept the previous snapshot, `Notifier` kept the last thing it
  /// had said, and neither of them could see a session's state, how a turn had
  /// ended, or whether a guardrail was in force right now. Every question this
  /// type answers was being answered by `workingCount` reaching zero.
  ///
  /// A value type driven by an injected clock, like `SessionStore` and
  /// `HookHealth` beside it, so a run can be walked start to finish in a test
  /// without waiting for any of it.
  public struct Watch: Sendable {

    /// How long a guardrail has to stay out of force before Vigil will warn
    /// about it a second time.
    ///
    /// Ten minutes, and it is hysteresis rather than a rate limit: the warning
    /// trips the instant a guardrail takes the hold away, and only re-arms once
    /// the condition has been *absent* for this long. A battery resting on its
    /// floor crosses it every few seconds — the model re-evaluates every five —
    /// and each crossing was a fresh time-sensitive alert with a sound, which
    /// is the one interruption level in this app that a Focus does not silence.
    /// So: long enough that no amount of chatter can ever accumulate it, short
    /// enough that a guardrail which genuinely cleared and came back hours
    /// later — unplugged again, hot again — is a new thing worth saying.
    public var guardrailRearm: TimeInterval

    /// The last whole-machine snapshot, so the guardrail rules speak on
    /// transitions rather than on every tick.
    private var previous: State?
    /// The same, one per host, for the rule that says a run has ended.
    ///
    /// A run belongs to a host, not to the Mac, and that distinction was the
    /// bug. Everything below that remembers something about "this run" is keyed
    /// the same way, for the same reason.
    private var previousPerAgent: [AgentKind: State] = [:]
    /// What each session was doing when we last looked, keyed on
    /// `AgentSession.id`, so an ending can be caught at the moment it happens.
    private var lastStates: [String: Seen] = [:]
    /// The worst thing that has happened to each host's run so far.
    private var outcome: [AgentKind: SessionOutcome] = [:]
    /// The hosts whose current run has had a guardrail stand between it and a
    /// hold.
    ///
    /// A guardrail is a fact about the Mac — one battery, one temperature — so
    /// it is recorded against every host that had something live at the moment
    /// it bit, and against no host that started afterwards. Cleared with the
    /// rest of that host's run.
    private var cutShort: Set<AgentKind> = []
    /// The guardrail Vigil last warned about, and when it stopped applying.
    private var warned: GuardrailKind?
    private var clearSince: Timestamp?

    /// One session as we last saw it. The host is carried because
    /// `AgentSession.id` is the only key available once the session is gone,
    /// and reading the host back out of it would mean parsing a separator.
    private struct Seen: Sendable {
      let agent: AgentKind
      let state: AgentState
    }

    public init(guardrailRearm: TimeInterval = 600) {
      self.guardrailRearm = guardrailRearm
    }

    /// Feed one pass of the loop in; get back the one thing worth saying.
    ///
    /// `expired` is what `SessionStore.prune` just gave up on, and it is not
    /// optional detail: a session pruned while it was still working is the only
    /// evidence Vigil ever gets that it lost an agent rather than watching one
    /// finish. `AppModel` had that array in its hand on the first line of every
    /// tick and threw it away before building the snapshot.
    public mutating func observe(
      sessions: [AgentSession],
      expired: [AgentSession] = [],
      isHolding: Bool,
      reason: WakeReason,
      completionSoundEnabled: Bool,
      now: Timestamp
    ) -> Spoken? {
      let states = Dictionary(
        sessions.map { ($0.id, Seen(agent: $0.agent, state: $0.state)) },
        uniquingKeysWith: { a, _ in a })
      for (agent, ending) in endings(among: sessions, expired: expired) {
        outcome[agent] = max(outcome[agent] ?? .finished, ending)
      }

      // Counted once and sliced two ways: whole-machine for the guardrails,
      // per host for the runs.
      var live: [AgentKind: (working: Int, waiting: Int)] = [:]
      for session in sessions {
        switch session.state {
        case .working: live[session.agent, default: (0, 0)].working += 1
        case .waiting: live[session.agent, default: (0, 0)].waiting += 1
        case .idle: break
        }
      }
      if !isHolding, reason.isGuardrail {
        // Every host that had something in flight when the guardrail bit, and
        // only those: one that starts afterwards is a new run in new conditions.
        for (agent, counts) in live where counts.working + counts.waiting > 0 {
          cutShort.insert(agent)
        }
      }

      let current = State(
        workingCount: live.values.reduce(0) { $0 + $1.working },
        waitingCount: live.values.reduce(0) { $0 + $1.waiting },
        isHolding: isHolding,
        reason: reason,
        outcome: outcome.values.max() ?? .finished,
        cutShort: !cutShort.isEmpty
      )
      let perAgent = Dictionary(
        uniqueKeysWithValues: Set(live.keys).union(previousPerAgent.keys).map { agent in
          (
            agent,
            State(
              workingCount: live[agent]?.working ?? 0,
              waitingCount: live[agent]?.waiting ?? 0,
              isHolding: isHolding,
              reason: reason,
              outcome: outcome[agent] ?? .finished,
              cutShort: cutShort.contains(agent)
            )
          )
        })
      rearmGuardrail(inForce: isHolding ? nil : GuardrailKind(reason), now: now)

      // No previous snapshot means this is the first tick after launch. Finding
      // agents already running is not a transition worth announcing.
      let spoken =
        previous.flatMap { was -> Spoken? in
          // A guardrail cutting in outranks a run ending, and it is judged for
          // the Mac as a whole because that is what a battery floor is about.
          //
          // On the announcement, not on the event. `record` returns nil for a
          // guardrail that is the same one all over again inside the hysteresis
          // window, and committing to this branch on the event alone meant that
          // suppression swallowed the run ending beside it — which the next tick
          // could never make good, because `previousPerAgent` advances below
          // whatever was said. A run that happened to finish on the same tick as
          // a repeat guardrail was announced by nothing at all: no chime, no
          // banner, no record of it having ended. Outranking is about which of
          // two things gets said; a thing that is not being said outranks
          // nothing.
          if let event = NotificationPolicy.guardrailEvent(from: was, to: current),
            let said = record(
              event, cutShort: current.cutShort, completionSoundEnabled: completionSoundEnabled)
          {
            return said
          }
          return runEnding(perAgent: perAgent, completionSoundEnabled: completionSoundEnabled)
        }

      previous = current
      previousPerAgent = perAgent
      lastStates = states
      // That host's run is over, whatever it was. Everything accumulated about
      // it goes with it, so its next run is not judged on this one's battery —
      // and, unlike before, neither is anybody else's. This used to wait for
      // every host on the Mac to fall quiet at once, which with four
      // integrations wired up is a state a working day may never reach: one
      // escaped Codex turn relabelled every clean run after it as a failure and
      // swapped the completion chime for the warning sound, for as long as the
      // user's own session kept something live.
      for (agent, state) in perAgent where state.liveCount == 0 {
        outcome.removeValue(forKey: agent)
        cutShort.remove(agent)
      }
      return spoken
    }

    /// The one thing worth saying about the runs that ended this tick.
    ///
    /// Per host, then folded back into a single announcement. The fold is not a
    /// compromise: `sound(for:…)` is a function of one event, and that is the
    /// whole reason three agents finishing within a few seconds of each other
    /// make one sound rather than three. Two hosts finishing on the same tick
    /// is the same situation one tick tighter, so it gets the same treatment —
    /// one sentence, the counts added, and the outcome the worse of the two,
    /// which is the same `max` a single host already applies across its own
    /// sessions.
    private mutating func runEnding(
      perAgent: [AgentKind: State],
      completionSoundEnabled: Bool
    ) -> Spoken? {
      var count = 0
      var worst = SessionOutcome.finished
      var wasCutShort = false
      for (agent, current) in perAgent {
        guard let was = previousPerAgent[agent],
          NotificationPolicy.runEndEvent(from: was, to: current) != nil
        else { continue }
        count += was.liveCount
        worst = max(worst, current.outcome)
        wasCutShort = wasCutShort || current.cutShort
      }
      guard count > 0 else { return nil }
      let event: Event =
        switch worst {
        case .finished: .allAgentsFinished(count: count)
        case .endedBadly: .runEndedBadly(count: count)
        case .lostContact: .lostContact(count: count)
        }
      return record(event, cutShort: wasCutShort, completionSoundEnabled: completionSoundEnabled)
    }

    /// How every session that left its run in this tick ended, per host.
    ///
    /// A session leaves by going `idle`, or by being pruned. The two are the
    /// same question asked a moment apart, and a Mac that slept through the
    /// middle of a run answers both at once: the closing event arrived, no tick
    /// ran to see it, and by the time one does the row has aged out. So the
    /// pruned rows are read for their own outcome first, and only a session
    /// that was still working or still waiting when it went counts as lost.
    private func endings(
      among sessions: [AgentSession],
      expired: [AgentSession]
    ) -> [AgentKind: SessionOutcome] {
      let here = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      let gone = Dictionary(expired.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      var worst: [AgentKind: SessionOutcome] = [:]
      for (id, was) in lastStates {
        // Only a session that was part of the run can leave it. One that was
        // already idle ended at the tick it went idle, and is not ending twice.
        guard was.state != .idle else { continue }
        // Still in the store: nil while it is live, its own outcome once it is
        // not. Gone from the store: pruned, and a session that vanished without
        // even being handed to us is one Vigil cannot vouch for either.
        let ending: SessionOutcome?
        if let session = here[id] {
          ending = session.outcome
        } else {
          ending = gone[id]?.outcome ?? .lostContact
        }
        guard let ending else { continue }
        worst[was.agent] = max(worst[was.agent] ?? .finished, ending)
      }
      return worst
    }

    /// Let a guardrail warning fire again once its condition has been clear for
    /// long enough to count as a separate occurrence.
    private mutating func rearmGuardrail(inForce active: GuardrailKind?, now: Timestamp) {
      guard let warned else { return }
      guard active != warned else {
        clearSince = nil
        return
      }
      guard let since = clearSince else {
        clearSince = now
        return
      }
      if now.seconds(since: since) >= guardrailRearm {
        self.warned = nil
        clearSince = nil
      }
    }

    /// Note that this is about to be said, and refuse a guardrail warning that
    /// is the same one all over again.
    ///
    /// `cutShort` is passed in rather than read off the instance: it is now a
    /// per-host condition, and the caller is the only one that knows whose run
    /// this sentence is about.
    private mutating func record(
      _ event: Event,
      cutShort: Bool,
      completionSoundEnabled: Bool
    ) -> Spoken? {
      if case .guardrailStoppedHold(let reason) = event {
        let kind = GuardrailKind(reason)
        guard kind != warned else { return nil }
        warned = kind
        clearSince = nil
      }
      return Spoken(
        event: event,
        sound: NotificationPolicy.sound(
          for: event.announcement,
          cutShort: cutShort,
          completionSoundEnabled: completionSoundEnabled
        )
      )
    }
  }
}
