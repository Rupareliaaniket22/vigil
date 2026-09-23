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

### Changed
- The panel is 340 × 375 instead of 340 × 558. Nothing was dropped: the agents
  and the processes holding your Mac awake are now one row at one height, the
  battery meter moved onto the status line, and the out-of-date banner became a
  line in the Agents heading that fixes every affected agent at once
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
- Gemini CLI reports `SessionEnd`, so a session torn down without a closing
  `AfterAgent` no longer holds the Mac awake until it expires
- An agent set up by an older version of Vigil is now visible as out of date
  rather than silently reporting less than Vigil listens for
- Session staleness is measured on a monotonic clock, so a clock correction
  cannot leave a dead session holding the Mac awake indefinitely
- Two agents that hand out the same session id are tracked as two sessions
  instead of merging into one attributed to the wrong agent
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
