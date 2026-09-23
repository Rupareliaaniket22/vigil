import Foundation

/// How a host shapes a hook entry in its settings file.
public enum HookEntryFormat: Sendable, Equatable {
  /// `"event": [ { "hooks": [ { "type": "command", "command": "…" } ] } ]`
  /// — Claude Code, Codex, Gemini CLI.
  case nested
  /// `"event": [ { "command": "…" } ]` — Cursor.
  case flat
}

/// One agent Vigil knows how to wire itself into.
///
/// Each host names its lifecycle events differently and keeps its settings
/// somewhere different, but they all take the same shape of hook entry, so the
/// differences live in data rather than in a branch per agent.
public struct AgentIntegration: Sendable, Identifiable, Equatable {
  public let id: AgentKind
  /// What to call it in the interface.
  public let displayName: String
  /// Settings file, relative to the user's home directory.
  public let settingsPath: String
  /// Events that mean the agent is mid-task.
  public let workingEvents: [String]
  /// Events that mean it is blocked on the user. Deliberately not a reason to
  /// hold the Mac awake — someone could be away for hours.
  ///
  /// Empty for Cursor alone. This comment used to say that Codex, Gemini CLI
  /// and Cursor published no such event, and for two of the three that was
  /// simply wrong — read from Vigil's own assumptions rather than from their
  /// sources:
  ///
  /// - **Gemini CLI** has declared `Notification` since its hooks shipped.
  ///   `HookEventName.Notification` is a first-class member of the enum and a
  ///   key in `schemas/settings.schema.json`, its only payload type is
  ///   `NotificationType.ToolPermission`, and `notifyHooks` awaits it in
  ///   `scheduler/confirmation.ts` on the line before the prompt goes up.
  /// - **Codex** has `PermissionRequest` in `HookEventName`, dispatched from
  ///   `Session::request_approval` as the *first* stage of approval — ahead of
  ///   Guardian and ahead of the user.
  ///
  /// So a Gemini or Codex session parked on a permission prompt read as
  /// `working` and held the Mac awake for the whole staleness window while
  /// nobody was there. Both are now listened for.
  ///
  /// Neither hook has to answer. Gemini's `NotificationOutput` carries no
  /// decision at all — only `suppressOutput` and `systemMessage` — and the
  /// call is wrapped in a `try`/`catch` that swallows a failing hook. Codex
  /// folds its handlers' verdicts and documents the empty case: handlers "can
  /// return a concrete allow/deny decision, or decline to decide and let the
  /// normal approval flow continue… otherwise there is no hook verdict", and
  /// `run_permission_request_hooks` returning `None` falls straight through to
  /// `request_reviewer_approval`. Vigil writes nothing to stdout, so both get
  /// no verdict from us, which is the outcome that changes nothing.
  ///
  /// One caveat, recorded because it is not visible from the event name.
  /// Codex's `PermissionRequest` runs before the *routing* decision, not
  /// before the *prompt* — so under Guardian or strict auto-review it fires
  /// for an approval no human will ever see, and Vigil reads `waiting` while
  /// Codex is in fact reviewing and working. That releases the hold for the
  /// length of the review. It is the lesser error: the release is undone by
  /// the next `PreToolUse` a moment later, whereas the bug it replaces held an
  /// unattended Mac awake for five minutes, and releasing rather than holding
  /// is the direction `state(for:)` already errs in on purpose.
  public let waitingEvents: [String]
  /// Events that mean it has stopped.
  public let idleEvents: [String]
  /// The host's own name for "the user stopped this turn", if it has one.
  ///
  /// Always one of `idleEvents` when present — it is an ending, and the hold
  /// has to be released for it. Named separately because "does this release
  /// the hold" and "does this host tell us about escape at all" are different
  /// questions, and only the second one has an answer Vigil has to live with.
  /// Nil means Vigil has no verified interrupt event for this host, which for
  /// Claude Code is a proven absence and for Gemini CLI and Cursor is simply
  /// unestablished — neither has been read for one.
  public let interruptEvent: String?
  /// Some hosts want a per-hook timeout in their config.
  ///
  /// Written verbatim as `"timeout"`, and the name of this field is only
  /// correct for the one host that uses it. Gemini CLI documents `timeout` as
  /// "execution timeout in milliseconds (default: 60000)", so 10,000 there
  /// means ten seconds. Codex reads the same key as *seconds* — its default is
  /// 600, and 1 for the two teardown events — so the same number would ask
  /// Codex for a timeout of nearly three hours. Nothing is broken today
  /// because Codex leaves this nil, and `CodexHookTrust.defaultTimeoutSeconds`
  /// therefore has the whole answer. Anyone setting it for Codex has to
  /// convert, and would be better off renaming this field first.
  public let timeoutMilliseconds: Int?
  /// Hosts do not agree on the shape of a hook entry.
  public let entryFormat: HookEntryFormat
  /// Whether writing the hook entry is enough to make the host run it.
  ///
  /// True for Codex alone, and it is not a detail: Codex keeps a `trusted_hash`
  /// per hook entry in `config.toml` and drops any entry without a matching one
  /// before it builds its handler list, so an untrusted entry never fires. A
  /// settings file that reads as perfectly installed can therefore be wired to
  /// a host that will not run a line of it — which is precisely what Vigil was
  /// reporting as "Reporting". `CodexHookTrust` is the check.
  ///
  /// The other three were read before this was left false for them:
  ///
  /// - **Claude Code** has no hook trust gate at all. Its documentation states
  ///   that "direct edits to hooks in settings files are normally picked up
  ///   automatically by the file watcher"; the only trust mechanism it
  ///   documents is workspace trust, and that governs hooks declared in a
  ///   project subagent's frontmatter, not `~/.claude/settings.json`.
  /// - **Cursor** gates *project* hooks on a trusted workspace. User hooks —
  ///   `~/.cursor/hooks.json`, which is the only file Vigil writes — carry no
  ///   trust record, no hash and no prompt.
  /// - **Gemini CLI** keeps `~/.gemini/trusted_hooks.json`, which looks like a
  ///   gate and is not one. `TrustedHooksManager` is consulted only for
  ///   *project* hooks, it warns rather than refuses — "These hooks will be
  ///   executed" — and it then trusts what it just warned about so it will not
  ///   warn twice. Folder trust can disable hooks wholesale, but that is a
  ///   decision about a workspace rather than a record about one entry, it is
  ///   off unless the user turns it on, and it is not something re-running
  ///   Vigil's installer could fix.
  ///
  /// Recorded here rather than branched on at the call site so the next host to
  /// grow a gate is one field, the way every other difference between hosts in
  /// this file is one field.
  public let requiresHookTrust: Bool

  /// The release at which this host became able to run a hook at all, and the
  /// command to look for to find out which release is installed.
  ///
  /// The third way a perfectly installed hook can be inert, after a missing
  /// event and a missing trust record, and the one with no trace in any
  /// settings file at all: a host that predates its own hook subsystem reads
  /// the `hooks` key, ignores it, and says nothing. Vigil wrote the entries,
  /// the file is immaculate, and not a line of it will ever run.
  ///
  /// Nil for three of the four, and nil means *not established* rather than
  /// *no floor* — the same distinction `interruptEvent` draws. Only Gemini CLI
  /// has been read for one:
  ///
  /// - **Gemini CLI** gained a hook subsystem that fires in `v0.19.0`. The
  ///   names arrived earlier and the machinery did not: `HookEventName` has
  ///   carried `BeforeAgent` and `AfterAgent` since `v0.17.0`, but at `v0.18.4`
  ///   the only references to either outside the hooks package are in
  ///   `hookAggregator.ts` and `hookRunner.ts` — nothing fires them. `v0.19.0`
  ///   is the first release where `core/client.ts` calls `fireBeforeAgentHook`
  ///   and `fireAfterAgentHook`, and the first that ships `hookSystem.ts` and
  ///   `hookEventHandler.ts` at all. Below it there is no setting, no flag and
  ///   no file that makes Vigil's hooks run.
  /// - **Claude Code, Codex and Cursor** have not been read for one. Guessing a
  ///   number here would produce exactly the confident wrong answer this field
  ///   exists to remove, and `HostHookSupport.verdict` returns `.notChecked`
  ///   for a nil floor, so nothing is claimed about them.
  ///
  /// One caveat that is not visible from the number, recorded because it is the
  /// reason this is a floor rather than an answer. Gemini CLI kept its hook
  /// system behind `experimental.enableHooks`, defaulting to **false**, from
  /// `v0.19.0` through `v0.23.0`; it defaults to true from `v0.24.0`, and later
  /// releases moved the switch to `hooksConfig.enabled`. So a copy at or above
  /// this floor may still be configured not to run hooks. That is a setting in
  /// the user's own file rather than a fact about the build, Vigil does not own
  /// it, and reading it would be a second claim on weaker evidence — so the
  /// floor answers only what it can: below it, nothing can help.
  public let hookFloor: HookFloor?

  public var allEvents: [String] { workingEvents + waitingEvents + idleEvents }

  /// What this host's event name means, in Vigil's terms.
  ///
  /// Anything unrecognised is treated as idle: assuming an unknown event means
  /// work would let a mislabelled hook hold the Mac awake indefinitely, which
  /// is the failure worth avoiding.
  public func state(for event: String) -> AgentState {
    if workingEvents.contains(event) { return .working }
    if waitingEvents.contains(event) { return .waiting }
    return .idle
  }

  /// Whether this host tells us when it is blocked on the human.
  ///
  /// False means a session of this agent sitting on a permission prompt counts
  /// as `working` until it goes stale — the hold outlives the work by up to the
  /// staleness window. Recorded rather than hidden so the gap is visible in one
  /// place instead of reading as an empty array someone forgot to fill in.
  public var hasBlockedOnUserEvent: Bool { !waitingEvents.isEmpty }

  /// Whether this host says anything when the user stops a turn by hand.
  ///
  /// The question `hasBlockedOnUserEvent` cannot answer, and the more
  /// expensive one to get wrong. A host that publishes an interrupt lets Vigil
  /// drop the hold the moment someone presses escape. A host that does not
  /// leaves the session reading `working` with nothing left to contradict it,
  /// so the hold outlives the work by up to the whole staleness window — and
  /// pressing escape is how most turns end.
  ///
  /// False for Claude Code, and that one is *proven* rather than merely
  /// unknown: its hook catalogue has no interrupt event and its `Stop` hooks
  /// are skipped on an aborted turn. See the note on `claudeCode`. Recorded
  /// here so the gap can be asserted on instead of living in prose.
  public var hasInterruptEvent: Bool { interruptEvent != nil }

  public init(
    id: AgentKind,
    displayName: String,
    settingsPath: String,
    workingEvents: [String],
    waitingEvents: [String] = [],
    idleEvents: [String],
    interruptEvent: String? = nil,
    timeoutMilliseconds: Int? = nil,
    entryFormat: HookEntryFormat = .nested,
    requiresHookTrust: Bool = false,
    hookFloor: HookFloor? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.settingsPath = settingsPath
    self.workingEvents = workingEvents
    self.waitingEvents = waitingEvents
    self.idleEvents = idleEvents
    self.interruptEvent = interruptEvent
    self.timeoutMilliseconds = timeoutMilliseconds
    self.entryFormat = entryFormat
    self.requiresHookTrust = requiresHookTrust
    self.hookFloor = hookFloor
  }
}

extension AgentIntegration {
  public static let claudeCode = AgentIntegration(
    id: .claudeCode,
    displayName: "Claude Code",
    settingsPath: ".claude/settings.json",
    workingEvents: [
      "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
    ],
    // Three names for "stopped on the human", and they are not
    // interchangeable.
    //
    // `PermissionRequest` — "When a permission dialog is displayed" — is the
    // precise one, and it is new here. The `Notification` beside it carries
    // the same news six seconds late: `permission_prompt` is fired from a
    // `setTimeout(…, 6000)` whose whole job is to avoid pinging for a prompt
    // the user answered straight away. Six seconds of holding the Mac awake at
    // an unattended prompt is not much; six seconds of Vigil's own UI saying
    // "working" when it is not is the part that reads as a bug.
    //
    // `Elicitation` — "When an MCP server requests user input" — was missed
    // entirely. An MCP elicitation is a modal question with no tool call
    // around it, so nothing else in this list fires for it and the session
    // read as `working` for as long as the dialog stood.
    //
    // Both are safe for a hook that says nothing. Claude Code documents
    // "Exit code 0 - use hook decision if provided" for one and "use hook
    // response if provided" for the other, and the elicitation handler is
    // explicit in code: `if (n) return n;` — falling through to the real
    // dialog when the hooks returned nothing. Vigil writes no stdout, so both
    // decline to decide. `Elicitation`'s exit code 2 *would* deny the
    // elicitation; Vigil's hook exits 0 on every path.
    //
    // `Notification` stays, and it is the uncomfortable one. It is an open
    // set — seventeen `notification_type` values today, with no promise there
    // will not be an eighteenth — and they do not agree with each other about
    // what is happening:
    //
    // - `idle_prompt` means the REPL is sitting at the prompt with nothing
    //   running. That is `idle`, not `waiting`.
    // - `permission_prompt`, `agent_needs_input`, `worker_permission_prompt`,
    //   `elicitation_dialog`, `elicitation_url_dialog` mean waiting — and the
    //   two dedicated events above now cover the cases that matter.
    // - `elicitation_complete` ("MCP server confirmed elicitation complete"),
    //   `auth_success`, `computer_use_exit`, `agent_completed`,
    //   `push_notification`, `quota_auto_resume_*` and `model_refusal_fallback`
    //   arrive *mid-turn*. Vigil reads `waiting` and drops the hold while the
    //   agent is still working.
    //
    // One name cannot mean three things, so this is wrong however it is
    // classified. It is kept as `waiting` because the alternatives are worse
    // and because the mistake it makes is the cheap one: a stray `waiting`
    // releases a hold the next `PreToolUse` takes straight back, while the
    // `idle` reading would announce "the agent finished, your Mac can sleep"
    // in the middle of a permission prompt — the bug `live()` exists to
    // prevent — and dropping `Notification` altogether would throw away
    // `idle_prompt`, which is the only thing Claude Code ever says after the
    // user presses escape. See the gap recorded below.
    //
    // The real fix is a `matcher` on `notification_type`: Claude Code
    // publishes one for this event, so Vigil could register several
    // `Notification` entries with different matchers and a different state
    // baked into each command, and the mapping would stay in Swift where it
    // is typed. That is a change to `HookConfiguration.install` (and to
    // `CodexHookTrust.hash`, which today refuses any matcher key), not to this
    // file, and it is the one worth making next.
    waitingEvents: ["Notification", "PermissionRequest", "Elicitation"],
    // `Stop` ends a turn; `SessionEnd` only fires when the whole session goes
    // away. Without `Stop`, every finished turn held the Mac awake until the
    // session went stale.
    //
    // `StopFailure` is the same event for a turn that ended badly — an API
    // error, a context overflow, a tool call that could not be parsed. Claude
    // Code dispatches it from its own code path (`executeStopFailureHooks`),
    // on the early returns out of the query loop, so a turn that fails is a
    // turn `Stop` never hears about. That is the missing-`Stop` bug wearing a
    // different name, and it was live: of 76 turns in one afternoon's hook
    // trace, 33 ended with no idle event at all, each holding the Mac awake
    // for the full staleness window afterwards. Listed even though `Stop` may
    // also fire on some of those paths — both mean idle, so an overlap costs
    // one redundant event and the gap costs five minutes.
    //
    // And here is what this list still does not cover, stated plainly because
    // the paragraph above reads as though it does.
    //
    // **Pressing escape fires nothing.** Claude Code has no `Interrupt` event
    // anywhere in its thirty-three-name hook catalogue, and the escape key is
    // not routed to one of the other thirty-two. Every main-turn `Stop`
    // dispatch hands the runner the turn's own abort signal —
    // `Fte(fe(h).mode, h.abortController.signal, …)` at the loop tick,
    // `Fte(Ye, y.abortController.signal, …)` at blockable turn end, the same
    // again for turn-end reactions — and the runner's first act is
    // `if (h?.aborted) return;`. Escape aborts that controller with
    // `"user-cancel"`, so by the time the `Stop` hooks are reached they are
    // already cancelled. `StopFailure` does not step in: it is dispatched only
    // from the API-error exits — rate limit, prompt-too-long, autocompact
    // thrashing, an unparseable tool call — and Claude Code's own summary of
    // it is "Fires instead of Stop when an API error … ended the turn."
    // `SessionEnd` fires when the session goes away, not when a turn does.
    //
    // So there is no event to listen harder for, and three things that look
    // like answers are not:
    //
    // - **Shortening `SessionStore.staleAfter` for this host.** The staleness
    //   window is not an interrupt budget; it is the longest tolerated gap
    //   between two hook events from a live session, and for Claude Code that
    //   gap is a single long tool call — `PreToolUse`, then silence until the
    //   test suite finishes. Five minutes is already tight for that. Cutting
    //   it would trade a rare over-hold for a common mid-run sleep and a false
    //   "Vigil lost contact" on every slow build, which is the failure this
    //   app exists to prevent.
    // - **`SubagentStop`.** It really does fire on an interrupted turn — the
    //   teardown path passes `void 0` for the signal, so it survives the abort
    //   that kills `Stop`. But it only fires when a subagent was running, it
    //   is classified `working` above because in every other case it means the
    //   parent turn continues, and reclassifying it would release the hold
    //   each time an `Agent` call finished mid-run.
    // - **`TeammateIdle`.** A real idle event, and deliberately not registered
    //   for: its payload is built from the *host session* (`jl(h.session, …)`)
    //   with the teammate named in a field, so a teammate parking while the
    //   main turn works would mark the whole session idle and drop the hold
    //   mid-run. Same shape as the mid-turn `Notification` values above.
    //
    // What actually covers it, partly and by accident, is `Notification` with
    // `notification_type: "idle_prompt"` — "Claude is waiting for your input",
    // armed whenever the turn stops loading and fired once the REPL has been
    // untouched for `messageIdleNotifThresholdMs`, 60 seconds by default. The
    // hook runs even for someone who has turned notifications off, because
    // the sender executes the hooks before it consults the channel. So escape
    // costs about a minute of holding the Mac awake rather than five — but
    // only as `waiting`, so the run never ends, no completion sound is played,
    // and the session lingers until it is pruned as `lostContact`. That is the
    // real cost of the gap, and it is the best available reading until either
    // Claude Code publishes an interrupt event or Vigil can discriminate on
    // `notification_type`.
    idleEvents: ["Stop", "StopFailure", "SessionEnd"]
  )

  public static let codex = AgentIntegration(
    id: .codex,
    displayName: "Codex",
    settingsPath: ".codex/hooks.json",
    workingEvents: ["UserPromptSubmit", "PreToolUse", "PostToolUse"],
    // Codex asks the human out loud, and Vigil used not to listen.
    //
    // `PermissionRequest` is a first-class member of Codex's `HookEventName`
    // and runs as stage one of `Session::request_approval`, whose own comment
    // gives the precedence: "1. Hooks. 2. If StrictAutoReview || Guardian
    // enabled, then Guardian. Else, user." A hook that returns nothing yields
    // `None` and the approval falls through to the normal reviewer, which is
    // exactly what Vigil's silent hook does. See `waitingEvents` for the one
    // case where this fires with no human involved.
    waitingEvents: ["PermissionRequest"],
    // `Interrupt` and `SessionEnd` are the two ways a Codex turn ends without
    // `Stop`: the user presses escape, or the terminal goes away mid-tool. Both
    // left the session reading `working` until it went stale — the same shape
    // as Claude Code's missing `Stop`, and the same five minutes of holding the
    // Mac awake for work that finished.
    //
    // `SessionStart` used to be here, on the reading that a session opening is
    // a session not yet working. That reading is wrong, and it was costing the
    // hold at the worst possible moment. Codex's `SessionStartSource` is
    // `{Startup, Resume, Clear, Compact, Fork}`, and `Compact` is not a
    // session opening at all: `Session::compact` queues
    // `SessionStartSource::Compact` as its last act, and the turn loop in
    // `session/turn.rs` drains that queue with
    // `run_pending_session_start_hooks` *inside the loop*, immediately after
    // `run_auto_compact(…, CompactionPhase::MidTurn)` and immediately before
    // it `continue`s. So a long Codex run that hits its context limit mid-turn
    // fires `SessionStart` while it is still working, Vigil flipped the
    // session to idle, and the hold was dropped for the whole post-compaction
    // model round trip — typically the slowest request in the session — until
    // the next `PreToolUse` took it back. On a Mac whose idle timer had
    // elapsed, that gap is enough to sleep mid-task.
    //
    // Dropped rather than reclassified. `working` would be worse — a terminal
    // opened and left alone would hold the Mac awake until it went stale — and
    // the other four sources buy nothing that the first `UserPromptSubmit`
    // does not deliver one prompt later. Codex does match `SessionStart`
    // handlers on the source string, so a `matcher` of everything but
    // `compact` would bring it back honestly; that needs
    // `HookConfiguration.install` to write matchers and `CodexHookTrust.hash`
    // to hash them, and neither does today.
    idleEvents: ["Stop", "Interrupt", "SessionEnd"],
    // Verified against `codex_protocol::protocol::HookEventName`, which is the
    // whole vocabulary: PreToolUse, PermissionRequest, PostToolUse,
    // PreCompact, PostCompact, SessionStart, SessionEnd, UserPromptSubmit,
    // SubagentStart, SubagentStop, Stop, Interrupt. Codex's `HookEventsToml`
    // has one field per event and ignores anything else in the file, so a
    // misspelling here would be silently dropped rather than reported — worth
    // having checked, and worth `CodexHookTrust.eventLabel` refusing a name it
    // does not recognise instead of inventing a snake_case form for it.
    interruptEvent: "Interrupt",
    requiresHookTrust: true
  )

  public static let gemini = AgentIntegration(
    id: .gemini,
    displayName: "Gemini CLI",
    settingsPath: ".gemini/settings.json",
    workingEvents: ["BeforeAgent", "BeforeTool", "AfterTool"],
    // Gemini's `Notification` is narrower than the word suggests, and that is
    // what makes it usable: `NotificationType` has exactly one case,
    // `ToolPermission`, and `fireToolNotificationEvent` is its only producer.
    // `notifyHooks` awaits it in `scheduler/confirmation.ts` on the line
    // before the tool call is moved to `AwaitingApproval` and the prompt goes
    // up, and only when `shouldConfirmExecute` actually returned details — so
    // it fires once, for a real question, at the moment it is asked.
    //
    // Nothing Vigil prints can get in the way: `NotificationOutput` has no
    // decision field, only `suppressOutput` and `systemMessage`, and the call
    // is wrapped in a `try`/`catch` that logs and carries on.
    waitingEvents: ["Notification"],
    // A session that is torn down without a closing `AfterAgent` — the terminal
    // closed, the host crashed — would otherwise stay `working` until it went
    // stale.
    idleEvents: ["AfterAgent", "SessionEnd"],
    // Gemini's own config carries a per-hook timeout; match its convention.
    timeoutMilliseconds: 10_000,
    // The one host read for a version floor, and the reason the field exists.
    // See `hookFloor` for how 0.19.0 was established and for the
    // `enableHooks` caveat that sits above it.
    hookFloor: HookFloor(executable: "gemini", since: HostVersion(0, 19, 0))
  )

  public static let cursor = AgentIntegration(
    id: .cursor,
    displayName: "Cursor",
    settingsPath: ".cursor/hooks.json",
    // Every one of these is an *observing* hook. Cursor divides its events in
    // two, and the division is the whole reason this list looks the way it
    // does. The permission side is **six** events as of Cursor 3.21.18, not
    // the four this comment used to name: `beforeShellExecution`,
    // `beforeMCPExecution`, `beforeReadFile`, `beforeTabFileRead`,
    // `subagentStart` and `preToolUse`. The last three are new, and all six
    // take the same `permission: allow | deny | ask` in their reply — so the
    // set Vigil must stand clear of grew without anything here noticing.
    //
    // `beforeSubmitPrompt` is *not* in that array, and it would be a mistake
    // to read that as "it cannot block". It blocks by a different shape, and
    // Cursor's own refusal builder is explicit about the split:
    //
    //     if (tqs(e))                      return { permission: "deny", … }
    //     if (e === Vu.beforeSubmitPrompt) return { continue: false,   … }
    //     if (e === Vu.sessionStart)       return { continue: false,   … }
    //
    // Three kinds of veto, not one. `hooks/vigil-hook.sh` already answers each
    // in its own currency — `{"permission":"allow"}` for the permission three
    // it once registered on, `{"continue":true}` for `beforeSubmitPrompt` —
    // which is why that script's `case` must be read as the historical set
    // Vigil wrote, not as a copy of Cursor's current permission array. It must
    // never grow to `beforeTabFileRead`, `subagentStart` or `preToolUse`: no
    // version of Vigil ever wrote those, so nothing can be left behind on
    // them, and answering would be voting on a hook we never registered.
    //
    // `sessionStart` vetoes the same way. Vigil registers on `sessionEnd` and
    // never on `sessionStart`, and this is the reason to keep it that way.
    //
    // What has *changed* is the cost of getting it wrong, and the old reading
    // is now too pessimistic in one specific way. It said Cursor treats
    // unparseable output, "including empty", as a block. That is no longer
    // true: `parseHookStdout` returns `{kind: "empty"}` as a distinct result,
    // and the consumer logs it and **fails open** unless the hook declared
    // `failClosed === true`. A hook that writes nothing therefore does not
    // block anything. The hazards that remain are non-empty malformed stdout
    // and an exit code of 2, neither of which Vigil's script produces — it
    // writes nothing to stdout and exits 0 on every path.
    //
    // The decision stands anyway, and the reason it stands is not the blocking
    // behaviour. A wake-lock utility has no business voting on whether an
    // agent may run a command. Registering on a permission hook makes Cursor's
    // agent depend on this script being present, fast and correct on the path
    // where a user is waiting, and it puts Vigil one Cursor release away from
    // being a gate again — the fail-open default is a default, and
    // `failClosed` is one key in a file. Standing aside costs nothing: every
    // `before*` is followed by the `after*` twin already listed here.
    //
    // Read out of `Cursor.app` on this machine, at
    // `Contents/Resources/app/out/vs/workbench/workbench.desktop.main.js` —
    // all seven names are in that bundle, including the three-way refusal
    // builder quoted above. What is taken on trust rather than read is
    // `parseHookStdout`
    // behaviour above are taken on report rather than read. Treat them as the
    // best available reading and not as something checked the way Codex's
    // `HookEventName` was.
    workingEvents: [
      "afterShellExecution", "afterFileEdit", "afterMCPExecution", "afterAgentThought",
    ],
    // afterAgentResponse closes a turn, so it means the agent has stopped.
    // sessionEnd is the teardown guard — the same one Gemini CLI needed.
    idleEvents: ["afterAgentResponse", "stop", "sessionEnd"],
    entryFormat: .flat
  )

  /// Every integration Vigil ships, in the order the settings window lists them.
  public static let all: [AgentIntegration] = [.claudeCode, .codex, .gemini, .cursor]

  /// What to call an agent in the interface.
  ///
  /// Events carry a raw kind, so a session can name an agent we ship no
  /// integration for. Falling back to the raw value keeps such a session
  /// visible — "claude-code" is still a better answer than nothing — but the
  /// four we know about read as their proper names, including to VoiceOver,
  /// which otherwise spells the hyphen out.
  public static func displayName(for kind: AgentKind) -> String {
    all.first { $0.id == kind }?.displayName ?? kind.rawValue
  }
}
