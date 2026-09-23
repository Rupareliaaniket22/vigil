# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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

### Changed
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
- Settings is 520 × 580 instead of 420 × 813, which no longer fills a 13"
  MacBook's screen top to bottom. Agents come first — it is the only section
  with something to do in it — then Power, Lid closed and Starting up
- The battery floor is chosen from Never, 10%, 15%, 20% and 30% instead of
  stepped one five-percent click at a time, and "Never" says what 0% meant
- Help text that only restated the control above it is gone

### Fixed
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
  does and says so in its own words: the agent reads "Not trusted", with no
  button, and a line underneath saying to open Codex and run `/hooks`. Its own
  state rather than a fold into "Out of date", because the two are fixed by
  opposite actions and an "Update" button here re-installs a file that was
  never the problem. It never writes a trust record: the gate exists so that a human read
  the command before their agent ran it, and an app granting itself that
  approval would have removed the only thing it is for.
  **If you set Codex up with an earlier build, run `/hooks` in Codex and trust
  Vigil's entries.** Claude Code, Cursor and Gemini CLI were checked for the
  same gate and have none for the files Vigil writes
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
