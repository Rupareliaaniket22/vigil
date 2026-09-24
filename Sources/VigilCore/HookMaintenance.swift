import Foundation

/// What Vigil may do to an agent's hooks without being asked.
///
/// The whole of the "do it, don't ask" decision, as one pure function, because
/// every part of it is a judgement about consent rather than about files —
/// which is exactly the kind of thing that must be readable, arguable and
/// tested rather than spread across the app layer as four `if`s.
///
/// The position it encodes, in one sentence: installing hooks is what Vigil is
/// *for*, so the first install needs no permission; keeping Vigil's own entries
/// current — including the record a host keeps of having approved them — is
/// maintenance of a job already granted, so it needs none either; and
/// everything that reverses a decision the user has actually made needs their
/// hand on it.
///
/// Nothing here is a secret, and that is the other half of the position. The
/// settings row says when Vigil recorded a host's approval for its own hooks,
/// the panel says which agents it set up and offers to undo it, and one switch
/// turns all of it off. A line of state is not friction; a modal is.
public enum HookMaintenance {

  /// The one thing Vigil would do to this agent right now.
  public enum Action: Sendable, Equatable {
    /// Write Vigil's hook entries into the host's settings file — either for
    /// the first time, or over entries an older version of Vigil wrote.
    case install
    /// Try to record the host's own approval — for entries Vigil recognises as
    /// byte-for-byte its own, and for no others. Often writes nothing.
    case trust
  }

  /// Whether to act, and how.
  ///
  /// - Parameters:
  ///   - state: what the agent's settings file says right now.
  ///   - manages: the user's answer to "set up and update agent hooks
  ///     automatically". Off means every branch below becomes a button.
  ///   - hasBeenSetUp: whether Vigil has ever written hooks for this agent on
  ///     this Mac. The record of a decision, not of a file — see below.
  ///
  /// `hasBeenSetUp` is what makes removal stick, and it is the only honest
  /// signal available. `notSetUp` is what a settings file looks like both
  /// before Vigil has ever touched it and after the user has taken Vigil's
  /// hooks out — the file cannot tell those apart, because in both cases there
  /// is nothing of ours in it. So the difference is remembered rather than
  /// read: the first install records that this agent has been set up, and that
  /// record is never cleared, including by the removal itself. An agent that
  /// has been set up once and is empty now is an agent somebody emptied, and
  /// Vigil putting the hooks back would be overruling them.
  ///
  /// It follows that this cannot distinguish "the user pressed Remove" from
  /// "the user deleted the entries by hand" or "the shared script went
  /// missing", and it deliberately does not try: all three mean *something
  /// removed Vigil's hooks after Vigil had installed them*, and the safe answer
  /// to all three is the same one. The cost is that a user who wants them back
  /// presses Set up, once.
  ///
  /// `outOfDate` needs no such memory and is not given any. It is only ever
  /// reachable when Vigil's own entries are already in the file, which is the
  /// evidence — in the user's own settings file rather than in Vigil's
  /// preferences — that this agent is one Vigil manages. That also makes the
  /// upgrade path work for somebody who installed hooks with a build that
  /// recorded nothing: their file still says so.
  ///
  /// `hostTooOld` is silent on purpose and always will be. Re-installing
  /// cannot change a state that exists precisely because the install is
  /// complete, and a Mac that quietly rewrote the same file on every panel
  /// open would be doing it forever.
  public static func action(
    for state: HookSetupState,
    manages: Bool,
    hasBeenSetUp: Bool
  ) -> Action? {
    guard manages else { return nil }
    switch state {
    case .ready, .hostTooOld:
      return nil
    case .outOfDate:
      return .install
    case .notSetUp:
      return hasBeenSetUp ? nil : .install
    case .untrusted:
      // The only case here that writes to a file belonging to the host rather
      // than to Vigil, and the one that needs its reasoning spelled out,
      // because it reads at a glance like a program approving itself.
      //
      // What Codex's `trusted_hash` covers is the hook *entry* — event name,
      // command string, timeout, matcher — and not the contents of the script
      // the command points at. `CodexHookTrust.identityJSON` is the whole of
      // what is hashed, and `vigil-hook.sh` is not in it. So the gate has never
      // protected the user against Vigil, and could not: what it protects
      // against is an entry appearing in `hooks.json` that the user did not
      // sanction. A record written only for an entry Vigil would itself write
      // cannot approve anything an attacker introduced.
      //
      // Which leaves the gate costing exactly one thing and buying nothing:
      // every Vigil release that alters a command invalidates every hash, and
      // the user is asked again for a decision they already made. A prompt
      // that fires on every release is a prompt people learn to click through.
      //
      // So it is not asked, ever — and the whole safeguard moves into
      // `CodexTrustWriter.selfWrittenRecords`, which is where the byte-for-byte
      // comparison lives and the only place an entry can qualify. This returns
      // "try", not "approve whatever is there": an entry that fails that
      // comparison gets no record, stays untrusted, and comes back here next
      // time with nothing to write.
      return .trust
    }
  }
}
