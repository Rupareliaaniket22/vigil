# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Vigil notices when a host is too old to run the hooks it installed. The row
  reads "Too old" and a note names the release the hooks arrived in, with the
  versions Vigil found. Gemini CLI grew them in 0.19.0; older copies read the
  settings Vigil wrote, ignore them, and say nothing. Vigil never concludes
  anything from absence — a host it cannot find is silent, because it cannot
  see `npx`, `mise`, an alias or a wrapper script, and calling a tool somebody
  uses daily "not installed" is worse than saying nothing at all
- Both of the blocking defects fixed above have permanent regression tests. The
  shared-hook-script delete rule runs in `make test` against a redirected home,
  so an uninstall can be driven through every way a sibling's settings file can
  fail to read without going near the developer's own `~/.claude`; the hook
  script's stdin bounds and its session-id recovery run in a new `make
  hooktest`, against a stand-in socket and a producer that never stops. Pointed
  at the code as it was, the first goes red on four of seven cases and the
  second on seven of thirteen
- Vigil knows when Codex and Gemini CLI are waiting on you. Both publish a
  permission event Vigil was not listening for — Codex's `PermissionRequest` and
  Gemini CLI's `Notification` — so a session parked on an approval prompt held
  the Mac awake for five minutes with nobody there. The comment claiming no host
  but Claude Code published such an event was simply wrong about two of them
- Claude Code permission prompts are noticed six seconds sooner, through the
  dedicated `PermissionRequest` event rather than the notification that is fired
  from a six-second timer, and a session stopped on an MCP elicitation is
  recognised at all
- Wake policy with battery floor, mains-only and Low Power Mode guardrails
- Agent session tracking with staleness expiry, so a crashed agent cannot pin the Mac awake
- Unprivileged `IOPMAssertion` wake hold
- System-wide power assertion readout — shows every reason the Mac is awake, not just ours
- Pluggable clamshell backend (sudoers now, `SMAppService` helper once signed)
- Universal build, bundle and ad-hoc signing with Command Line Tools only
- Menu bar panel, settings window, and one-click hook setup
- Integrations for Claude Code, Codex, Gemini CLI and Cursor
- Notifications when a run finishes or a guardrail cuts one short
- Lid-closed support behind a scoped sudoers helper
- ⌥⌘L to toggle the manual hold from anywhere
- Thermal ceiling: the hold is released when the Mac runs hot
- The panel says when an agent's hooks are out of date, with one action to fix it
- Vigil notices when a host stops saying its work has finished. `HookSetupState`
  has only ever watched *our* expected event set drift; this watches the host's,
  by tracking how sessions end — because it told us, or because we gave up on
  it. A host that has quietly renamed or dropped an idle event shows up as
  sessions that consistently run out the clock. It is a ratio over the last
  twenty endings rather than a count, because an agent genuinely killed
  mid-run expires exactly the same way, and it says nothing at all below eight
  endings or at a timeout share of half or less
- Vigil checks the lid-closed helper against the copy it ships. The helper runs
  as root behind a passwordless `sudoers` rule and is installed once and never
  looked at again, so an app updated without it drifts apart from it in silence.
  A hash mismatch now reads as "installed by a different version of Vigil",
  which is the whole of what a hash mismatch means — writing to
  `/Library/PrivilegedHelperTools` already needs root, so it is not evidence of
  anything worse
- One press in Vigil to let Codex run its hooks, with what is being approved
  shown first. Codex keeps a `trusted_hash` per hook entry and silently drops
  every entry it has no record for, so the only fix used to be to leave Vigil,
  open Codex and run `/hooks`. An agent reading "Not trusted" in Settings now
  carries a "Trust…" button: pressing it opens what would be written — the
  command, the events it would run on, and the file the records land in — and
  writes none of it until Approve. The two presses are deliberately separate.
  A button that recorded the approval on the first one would be an app granting
  itself the permission the gate exists to ask a human for, which is the thing
  Vigil already refuses to do on install, and it would go on granting it to a
  future Vigil whose hook script had been tampered with. `config.toml` is
  copied before it is touched, is written atomically so an interrupted press
  cannot truncate it, and comes back byte-for-byte apart from the
  `trusted_hash` lines — comments, ordering and every other setting included.
  Where it already records a hook in a shape Vigil cannot rewrite without
  risking a file Codex can no longer parse at all, Vigil changes nothing and
  says to use `/hooks` instead
- A sound when a run finishes. The notification Vigil already sent when the
  last agent stopped now carries the system "Glass" chime and arrives as a
  banner instead of silently in Notification Center, with a switch under
  Agents in Settings to put it back the way it was. It is a
  `UNNotificationSound` rather than anything Vigil plays itself, so Focus, Do
  Not Disturb and a notification permission that was never granted each
  silence it without Vigil deciding when somebody may be disturbed — which is
  the whole difference between a chime at the end of an overnight run and one
  at 3am. One sound per run and not per agent: three agents stopping within a
  few seconds of each other is one ending, not three. A run a guardrail cut
  short does not get it — that already has its own time-sensitive alert, and a
  "done" chime a minute after "your run may not finish" is the app
  contradicting itself. What counts as a finished run, and what the other two
  kinds of ending say instead, is under Fixed. No audio file is added to the
  repository: `Glass.aiff` is one macOS has shipped for decades, so there is
  nothing here to license or keep

### Changed
- The settings window's worst-case height check reads the hosts that gate hooks
  off the integrations instead of assuming Codex is the only one. Each trust
  notice costs 32pt, so a second gating host measures 680 of 680 and a third
  fails the build, on the build that introduces it
- `make smoke` builds the panel in its worst shape — every trust notice and a
  capped installer error — and the degraded gallery carries the hook-health
  warnings no fixture can otherwise arrange
- The panel is 340 points wide and about a third shorter than it was. The width
  is the fixed half and `make smoke` fails the build if it moves; the height has
  always followed the content, which is what a single number here was hiding.
  Today `make smoke` measures 280 points with nothing running and 435 with five
  agent rows and three ledger rows. Nothing was dropped: the agents and the
  processes holding your Mac awake are now one row at one height, the battery
  meter moved onto the status line, and the out-of-date banner became a line in
  the Agents heading that fixes every affected agent at once
- The manual switch moved from beside the headline into the footer, reading
  "Always keep awake". While a guardrail is holding it down it says which one,
  rather than being greyed out with no explanation
- The battery readout is the system battery glyph beside the number, in place
  of a 24-point bar whose empty track was invisible against the panel
- Pausing is two rows in the panel instead of a submenu that drew outside it
- Settings is 520 × 680 instead of 420 × 813, which no longer fills a 13"
  MacBook's screen top to bottom. Agents come first — it is the only section
  with something to do in it — then Power, Lid closed and Starting up
- The battery floor is chosen from Never, 10%, 15%, 20% and 30% instead of
  stepped one five-percent click at a time, and "Never" says what 0% meant
- Help text that only restated the control above it is gone

### Fixed
- A hook installed by a version of Vigil older than the quoting fix reads as out
  of date and offers "Update". Vigil recognised its own hooks by the script's
  filename alone, so an entry with an unquoted path — which fails silently on a
  home directory containing a space — and the wrong state baked into every
  event counted as a healthy install
- A settings row for an agent whose hooks are installed reads "Installed"
  rather than "Reporting". That word is read off a settings file and says
  nothing about whether the agent has ever run
- Corrected Vigil's record of how Cursor can refuse. There are three shapes, not
  one: six permission hooks answer `permission: deny`, while `beforeSubmitPrompt`
  and `sessionStart` refuse with `continue: false`. Reading "not a permission
  hook" as "cannot block" would have dropped `beforeSubmitPrompt` from the
  script's disarm list, which is why the comment now names all three. Cursor
  also no longer blocks when a hook writes nothing
- Uninstalling one agent no longer deletes the hook script every other agent is
  using. One script serves all four, so it is removed only once nothing points
  at it — but the check read a settings file it could not open as "this agent
  does not use it". Malformed JSON, a JSON comment, a root that is not an
  object, a file or a directory with the wrong permissions: each silently voted
  to delete. Three agents in any of those states and uninstalling the fourth
  took the shared script out from under all of them, leaving hook entries that
  still read as perfectly correct pointing at a file that is not there — nothing
  fires, and the first anyone hears of it is a Mac that slept in the middle of
  an overnight run. The question has three answers now rather than two, and only
  a definite "nobody points at this" removes anything
- Vigil's hook can no longer hold up the agent that ran it. Its read of the
  host's payload was bounded by volume — 64KB and 4096 lines — and not by time,
  and the one-second timeout was per *line*, so any host emitting a line more
  often than once a second kept the loop alive indefinitely: 10.99 seconds for
  ten lines, 19.49 for twenty, strictly linear, with the line bound putting the
  worst case a little over an hour. It exited 0 throughout and posted nothing,
  so the only symptom was a coding agent that stalled for no visible reason. The
  read now carries a two-second wall clock as well, after which the event is
  posted with whatever arrived. A payload that turns up at once, which is every
  real one, still takes about a tenth of a second
- A payload that arrives in pieces no longer strands a session in "working". Cut
  short mid-object it is no longer JSON, so nothing could be read out of it and
  the event was filed under the process id — the one key the matching idle event
  never uses, because that payload is small, parses, and carries the real
  session id. The phantom left behind held the Mac awake until it went stale. A
  payload that will not parse is now scraped for its session id before anything
  falls back to the pid
- Codex no longer reads a mid-turn compaction as a finished session. It re-fires
  `SessionStart` with source `compact` from inside its turn loop, so a long run
  that hit its context limit released the wake hold for the whole
  post-compaction model round trip — typically the slowest request in the
  session. `SessionStart` is no longer registered as an ending
- A finished run is no longer relabelled a failure by an unrelated one. The
  worst-outcome accumulator was global and cleared only when nothing anywhere
  was working or waiting, so with several agents wired up one escaped turn
  swapped the completion chime for the warning sound on every clean run after
  it. Outcomes are tracked per agent now
- A settings file whose permissions Vigil could not read is written back at 0600
  rather than at whatever the umask gives, so a file that can hold API keys is
  never quietly widened
- The completion chime fires when a run actually finished, and not otherwise.
  It was triggered by nothing being in the `working` state, which is four
  different things wearing one face. An agent that stops to ask permission is
  not working either, so every approval prompt announced "Agent finished — your
  Mac can sleep normally now", with the chime, while the agent sat at the
  prompt: N approvals were N+1 chimes, for everyone not running in
  bypass-permissions mode. The banner had been doing this since notifications
  shipped; adding a sound is what made it audible. A turn that ended on Claude
  Code's `StopFailure` — an API error, a context overflow, an unparseable tool
  call, a third of the turns in one afternoon's trace — or on Codex's
  `Interrupt`, which is the user pressing escape, was announced as work waiting
  to be collected. So was a session Vigil had simply lost: a host that crashed,
  a terminal that closed, a Mac that woke with the run already gone.

  A run is now live while any session is working *or* waiting on its user, it
  ends when the last of them does, and how it ended is carried rather than
  guessed. Three endings, three things to say. A run that finished chimes. A
  run that stopped without finishing says so. A run Vigil lost track of says
  that instead — "It stopped reporting, so Vigil is no longer holding your Mac
  awake. It may not have finished." Both of those make a sound, because
  somebody in another room is waiting on one, and neither makes *that* sound:
  the chime is a promise that the work is there when you get back. Neither is
  time-sensitive either — the one alert that breaks through a Focus is still
  the one about work that can still be saved
- A run a guardrail killed no longer chimes just because the guardrail never got
  a word in. The suppression asked what Vigil had last announced, which missed
  the case where there was nothing to announce: pause Vigil, let the battery
  fall below its floor during the pause, and the guardrail is in force having
  said nothing, because no hold ever ended. The Mac then slept, the agent died,
  and the run was congratulated. It now asks whether a guardrail stood between
  this run and a hold at any point — a condition, not a history — and clears
  when the run ends, so tomorrow's run is not judged on today's battery
- A battery resting on its floor no longer chatters. The "Vigil stopped holding
  your Mac awake" alert is the one notification here at time-sensitive
  priority, which is the one level a Focus does not silence, and a charge
  hovering at the floor crossed it on a five-second tick — five minutes of that
  was thirty alerts with sound. The warning trips at once and re-arms only
  after that guardrail has been out of force for ten minutes, which no amount
  of chatter can accumulate. Heat and the battery are told apart, so one being
  quiet does not quiet the other
- Reinstalling the lid-closed helper reports an install that landed but left the
  helper unreachable, in the same words the lid-closed switch already used,
  instead of reporting success and sending you back to a control that still
  would not work
- Cmd-W dismisses the menu bar panel. It never did: the panel has no close
  button, so AppKit disabled Window > Close whenever the panel was the target,
  and a disabled menu item still matches the key equivalent — the keystroke was
  swallowed and `performClose` was never called once. The panel now validates
  that one item for itself
- Notes in the panel no longer install an empty tooltip when they have no longer
  text behind them, which also removes an empty VoiceOver help attribute
- The note about a host that will not run Vigil's hooks now says "Trust them in
  Settings", the same word as the Trust… button that does it
- The settings window can no longer cut off its own last control. It is a fixed
  520 x 680 with no scroll view and no resize handle, and two of the blocks in
  it are text Vigil did not write — a host's reason for refusing our hooks, and
  an installer's own output, which `ClamshellInstaller` passes through
  untouched and which therefore has no length at all. Past the window's height
  the overflow was clipped by the window edge with nothing indicating it: what
  went was the bottom, the "Open Vigil at login" switch and the note under it,
  controls still notionally on screen and out of reach. Both blocks are now
  capped with the whole of the text on the hover, and `make smoke` measures the
  worst shape the window can be in rather than whatever the machine that built
  it happened to be showing — every agent offered, an untrusted host, an error
  long enough to reach its cap, and each of the two things the lid section can
  say. That worst case is 648 points against a window of 680; the old check
  only ever saw this machine's 570, so the one input that can grow without
  bound was the one input it never exercised
- Vigil says when the lid-closed helper is not the one it ships. The check has
  existed for a while and nothing rendered its verdict: a root-owned script
  that no longer matches the app driving it, computed every five seconds and
  shown to nobody. The Lid closed section now carries a row for it — what it
  is, that it is out of date, and the one press that reinstalls it — with the
  reason on the hover. Reinstalling was not previously reachable either: the
  switch installs only when nothing is installed at all, so a drifted helper
  had no route back
- The right-hand column of the settings window lines up. Every switch track in
  it sits on the window's own margin, while the buttons beside the agent rows
  and the value menus stopped 12 points short of it — our plain button draws no
  background at rest, so the capsule taking that space was invisible and the
  column simply jumped left on the rows asking to be clicked
- Cmd-W closes the menu bar panel instead of beeping at you. The panel has no
  close button for `performClose` to press, so AppKit answered the reflex
  gesture for dismissing a focused surface with the system error sound
- The settings window reopens where it was left, including on another display.
  It kept its position within a session and forgot it on every relaunch,
  reverting to the centre of the main screen
- Vigil no longer puts a Mac to sleep that it was never keeping awake. With the
  lid shut — a laptop on a stand driving an external display, all day — any
  guardrail that merely *applied*, with no agent running and nothing
  overridden, asked for an immediate sleep, every five seconds. It now asks
  only where a guardrail has taken away a lid-closed hold Vigil would otherwise
  have had
- Pausing no longer sends the alert meant for a guardrail. Pausing with an agent
  running dropped the hold, which read as a safety cutoff: Vigil interrupted
  with a sound to say a run "may not finish" because of something the user had
  just chosen from its own menu
- A Mac mini with a UPS attached is no longer read as a laptop. The first power
  source IOKit lists is not necessarily the Mac's own battery, so the panel
  showed the UPS's charge as a battery meter and the floor stood ready to stop
  a run over it
- Low Power Mode is reported on a Mac with no battery, which Apple silicon
  desktops can be in too
- A battery the SMC has not answered for yet reads as full rather than as flat,
  so a machine still waking up does not refuse to hold a run for a battery that
  is charged
- The panel opens with nothing focused, like a menu. It used to open with a
  focus ring around the first footer row every time, and reopen with whichever
  row was last focused still lit; Tab or an arrow key now brings focus in
- The footer switch's focus ring sits on the same inset rounded rectangle as
  the menu rows' highlight, instead of at the text margin
- The gap above "Also holding your Mac awake" matches every other section break
- "Always keep awake" fits beside every guardrail phrase; the old label was two
  points too wide beside "Low Power Mode" and ended in an ellipsis
- `pmset -g assertions` no longer shows Vigil's reason with a "?" in the middle
  of it: the assertion name is folded to ASCII by construction rather than by
  anyone remembering to
- The panel no longer shows an agent twice — once for its live session and once
  offering to set it up
- Internal error text no longer appears in the panel. Errors that used to print
  a socket path and an errno now read as sentences, with the original on the
  tooltip and in the log
- A bridge that fails to start can be retried from the panel instead of needing
  Vigil restarted
- Claude Code's `Stop` event is listened for again, so a finished turn releases
  the hold immediately instead of waiting out the staleness window
- Cursor's agent is no longer blocked by Vigil's own hook. Four of the events
  Vigil registered for — `beforeShellExecution`, `beforeReadFile`,
  `beforeMCPExecution` and `beforeSubmitPrompt` — are hooks Cursor waits on for
  a verdict, and it treats output it cannot parse, empty output included, as a
  refusal. Vigil's hook prints nothing, so setting Cursor up meant every shell
  command, file read, MCP call and prompt in Cursor was denied by a wake-lock
  script. Vigil now registers only on events Cursor merely observes, and
  reinstalling sweeps the old entries out. **Anyone who set Cursor up with an
  earlier build should re-run Cursor's setup.**
- A Claude Code turn that ends badly releases the hold. `StopFailure` — the
  event for a turn cut short by an API error, a context overflow or an
  unparseable tool call — is dispatched instead of `Stop`, so those turns ended
  in silence and held the Mac awake for the full staleness window. In one
  afternoon's trace that was 33 turns out of 76
- Codex is no longer reported as "Reporting" when Codex is running none of
  Vigil's hooks. Codex keeps a `trusted_hash` for each hook entry in
  `~/.codex/config.toml` and drops every entry without a matching one before it
  assembles the hooks it will run, so writing the entry is not the same as
  installing it — and Vigil was reading `hooks.json` alone. Worse, the record is
  keyed on the entry's *position*, so where another tool's hook already held
  matcher index 0, the record that looked like ours belonged to them. On the
  machine this was found on that meant five trust records, seven Vigil entries,
  and not one of them trusted. Vigil now computes the same identity hash Codex
  does and says so in its own words: the agent reads "Not trusted", with a line
  underneath saying what Codex is doing and what resolves it. Its own state
  rather than a fold into "Out of date", because the two are fixed by opposite
  actions and an "Update" button here re-installs a file that was never the
  problem. Vigil never records the approval on its own — see the trust
  confirmation under Added: the gate exists so that a human read the command
  before their agent ran it, and an app granting itself that approval would
  have removed the only thing it is for.
  **If you set Codex up with an earlier build, press Trust beside Codex in
  Settings, or run `/hooks` in Codex.** Claude Code, Cursor and Gemini CLI were
  checked for the same gate and have none for the files Vigil writes
- Codex sessions that are interrupted or whose terminal closes release the hold,
  via `Interrupt` and `SessionEnd`
- Cursor sessions are identified by conversation. Cursor sends
  `conversation_id` and nothing called a session, so every Cursor event fell
  back to the hook's parent pid and a window's whole history collapsed into one
  row
- The hook no longer spends 22 seconds inside the agent on a large
  pretty-printed payload. Reading it a line at a time built the string and
  re-measured it quadratically; the same input now takes about 0.2 seconds
- The hook is silent on stderr when a host hands it a closed stdin, instead of
  printing "read error: 0: Bad file descriptor" inside the agent
- A hook payload with an enormous `session_id` or `cwd` is trimmed rather than
  building a body the bridge refuses, which lost the event outright
- Vigil no longer overwrites a hook entry it doesn't recognise. A `hooks` value
  shaped differently from what its host documents read as an empty slot and was
  replaced, so installing Vigil could silently delete another tool's hook. It
  now says which entry it left alone and why
- A settings file containing only whitespace is treated as empty instead of
  being refused as invalid JSON
- Stopping the bridge no longer reports a failure. Quitting or retrying tore
  the listening socket out from under its own poll, and the resulting
  "kqueue kevent(9): Bad file descriptor" was reported as a fault — landing,
  on a retry, on top of the healthy bridge that had just replaced it
- Vigil removes its socket file when it stops. The status it checked before
  deleting was only ever written by the two paths that fail before the server
  starts, so a working bridge's status stayed on "starting" and the file was
  always left behind
- An agent still carrying hooks for events Vigil has stopped listening for
  reads as out of date, rather than as perfectly set up while the retired hooks
  go on firing
- The hook's debug log refuses to follow a symlink. `/tmp` is world-writable,
  so another account on the Mac could point that name at a file of yours
- Gemini CLI reports `SessionEnd`, so a session torn down without a closing
  `AfterAgent` no longer holds the Mac awake until it expires
- An agent set up by an older version of Vigil is now visible as out of date
  rather than silently reporting less than Vigil listens for
- Session staleness is measured on a monotonic clock, so a clock correction
  cannot leave a dead session holding the Mac awake indefinitely
- Two agents that hand out the same session id are tracked as two sessions
  instead of merging into one attributed to the wrong agent
- A control that becomes unavailable while the pointer is on it, or while it is
  held down, now goes dark. It used to keep its hover fill or its press tone —
  dimmed, but still lit — because neither the pointer nor the mouse button had
  moved, so nothing told it to redraw, and a control frozen half-pressed reads
  as broken rather than as unavailable
- Rows in both lists move as one piece when a session appears or disappears.
  The dot, the name, the path and the elapsed time each used to settle at their
  own rate, so for a couple of frames the row re-columned itself in mid-air
- Clicking the menu bar icon while the panel is open closes it, instead of
  closing and immediately reopening it
- The panel resizes when its content changes while it is open, rather than
  clipping the rows that appeared
- A prompt containing non-ASCII characters no longer makes the hook drop the
  whole event
- The hook no longer waits forever for a host that does not close its stdin
- A read-only settings file is refused rather than silently replaced, its
  permissions are preserved, and a file with comments in it says so
- Vigil no longer rewrites a settings file when the contents would not change
- The assertion ledger is only sampled while the panel is open
- Quitting is safe from a signal handler again. The handler that clears the
  lid-close flag on `SIGINT`, `SIGTERM` and `SIGHUP` went through `FileManager`,
  `URL` and `Process` — all three allocate and all three touch the Objective-C
  runtime, none of which is safe in a signal context. A signal arriving while
  the allocator was busy could wedge the very path that stops a Mac being left
  unable to sleep. Everything the handler needs is now worked out at launch, and
  the handler itself uses only calls `sigaction(2)` lists as async-signal safe
- A pause ends when it says it does. It was measured on the wall clock, so an
  NTP correction backwards — which a laptop takes within seconds of waking from
  a week asleep — silently extended a ten-minute pause by the size of the step,
  leaving agents working with nothing holding the Mac awake. Pauses are measured
  on the monotonic clock now, like everything else that expires; "Paused until
  5:30 PM" still reads off your own clock
- Vigil says when it is *not* holding your Mac awake, not only when it stops.
  Starting a run with the battery already below the floor produced no hold and
  no word about it, because nothing transitioned — the warning only ever watched
  a hold end. It now also speaks up when work begins underneath a guardrail
- The panel copes with a first responder that refuses to let go. Clearing the
  focus on open could fail silently, and the visible result was the focus ring
  it exists to prevent
