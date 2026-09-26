# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [0.1.0] - 2026-09-27

Vigil's first release. A menu bar app that holds your Mac awake while an AI
coding agent is actually working, and lets it sleep again the moment that stops
— so an overnight run does not die when the Mac does.

- Reads the lifecycle hooks **Claude Code**, **Codex**, **Gemini CLI** and
  **Cursor** already publish, so it can tell a run in progress from a terminal
  left open
- Sets those agents up on first launch, without asking, and then says so: the
  panel opens itself once, names the agents, and offers an Undo. Every file it
  edits is copied to `<file>.vigil-backup` before its first edit, nothing else
  in that file is changed, one Vigil cannot parse is left alone, and one switch
  in Settings turns the whole behaviour off
- Guardrails come first. It lets go when your Mac runs hot, below a battery
  floor you choose, on battery if you ask it to, and in Low Power Mode — and a
  session that stops reporting expires, so a crashed agent cannot pin your Mac
  awake
- Shows everything keeping your Mac awake, not only its own hold
- Tells you when a run finishes, and warns you when a guardrail cuts one short
- Works with the lid closed if you turn it on, behind a root-owned helper that
  changes that one setting and nothing else
- ⌥⌘L to hold your Mac awake from anywhere
- Removes itself: **Remove Vigil from This Mac…** in the Vigil menu takes its
  hooks back out of every agent, and `uninstall.sh` inside the app bundle
  removes everything else, including the root-owned half

Known limits: there is no auto-update; OpenCode uses a JavaScript plugin rather
than shell hooks; and desktop apps other than Cursor publish no lifecycle events
and hold no wake lock of their own, so Vigil cannot see them working and will
not guess.

## Pre-release development

Everything below this heading happened before the first release, so none of it
ever shipped to anyone. It is kept because the reasoning is worth having, and it
is under a heading of its own so that `Scripts/changelog-section.sh` — which
stops at the next `## ` — leaves it out of the release notes rather than handing
`gh release create` six hundred lines of diary.

### Added
- Vigil shows you what it did, on the one launch it does it. The panel already
  said which agents were set up and offered an Undo, and nobody ever saw it: a
  menu bar app is one you do not open, so on the launch where Vigil arrives and
  writes a hook into four other programs' config files, that notice sat behind a
  closed panel and was cleared the first time it was opened and shut for some
  unrelated reason. The panel now opens itself, once, on the first run that
  actually installed something. It costs no click — the next click anywhere
  dismisses it, like any menu — and it is not a question: everything in it has
  happened, and the Undo is beside it
- **Remove Vigil from This Mac…**, in the Vigil menu. Takes Vigil's hooks out
  of every agent it set up, withdraws the approvals it recorded for them and
  turns off Open at Login, in one press rather than four — then says what is
  left and where the uninstaller is. It is the half of an uninstall only the app
  can do: `Scripts/uninstall.sh` will not edit the four agents' config files on
  purpose, because removing one entry from somebody's JSON or TOML without
  disturbing the rest of it is what `HookConfiguration` does with tests behind
  it and what a shell script cannot do safely
- Vigil sets itself up. On first run it installs its hooks into every agent it
  finds — and, where a host will not run a hook until its own config records an
  approval, writes that record too — then says so in the panel: which agents,
  where an approval was recorded, and an Undo beside it. Installing hooks is
  the whole of what Vigil does to be useful, so the first one is not a question
  worth putting to somebody who has just installed the app whose job it is
- Removal sticks. An agent the hooks have been taken out of is never wired back
  up on its own, however many times the panel is opened. Vigil remembers which
  agents it has set up rather than reading it off the settings file, because a
  file with none of our hooks in it looks identical before the first install and
  after a removal — and it deliberately does not try to tell a Remove press from
  a hand-edit or a missing script, since all three mean somebody took them out
  and the safe answer to all three is the same
- "Set up and update agent hooks automatically", in Settings, on by default. Off
  restores exactly the behaviour Vigil had before: every state that could have
  been put right on its own grows a button and waits
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
- Vigil can write Codex's hook trust records itself. Codex keeps a
  `trusted_hash` per hook entry and silently drops every entry it has no record
  for, so the only fix used to be to leave Vigil, open Codex and run `/hooks`.
  `config.toml` is copied before it is touched, is written atomically so an
  interrupted write cannot truncate it, and comes back byte-for-byte apart from
  the `trusted_hash` lines — comments, ordering and every other setting
  included. Where it already records a hook in a shape Vigil cannot rewrite
  without risking a file Codex can no longer parse at all, Vigil changes
  nothing and says to use `/hooks` instead. This entry used to describe a
  "Trust…" button and a confirmation behind it, and argued that anything less
  would be an app granting itself a permission the gate exists to ask a human
  for — including "to a future Vigil whose hook script had been tampered with".
  That last clause was wrong about what the hash covers, and it is what the
  entries under Changed correct
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
- The README, SECURITY.md, AGENTS.md, CONTRIBUTING.md and docs/PLAN.md say that
  Vigil sets agents up at launch without asking, above the command that does it.
  SECURITY.md gains a third component worth scrutiny — writing into other
  programs' configuration files — with the byte-for-byte bound on what Vigil may
  approve, and four things that bound does not cover
- Vigil keeps its own hook entries current without asking. Every release that
  changes a hook command used to leave every agent reading "out of date", with a
  banner and a click each; Vigil has already been granted management of those
  entries, and keeping them current is maintenance rather than a new decision.
  An agent the user removed is still never touched
- Codex's hook trust is no longer something to press. The `Trust…` button and
  its confirmation dialog are both gone; Vigil writes the trust record for its
  own hook entries itself, first run and after every release that changes a
  command. Nothing about it is hidden: the settings row reads "Installed,
  approved by Vigil" for as long as that record is in the file, with what was
  written and the limit on it on the hover, and the panel says so at the moment
  it happens
- That approval is written only for an entry whose command is byte-for-byte
  what this version of Vigil writes for that integration and registration, with
  the same matcher and no hand-written timeout — and that comparison is now the
  only safeguard there is, so it is worth reading. Anything that fails it gets
  no record, leaves the host still refusing that one entry, and surfaces in the
  interface pointing at the host's own review command. The reasoning: Codex's
  `trusted_hash` covers the hook *entry* — event name, command string, timeout,
  matcher — and not the contents of the script the command points at. Editing
  `vigil-hook.sh` has never invalidated a hash and never could, so the record
  was not a gate against Vigil; what it guards is an entry turning up in
  `hooks.json` that the user did not get, and a record written only for entries
  Vigil would itself write cannot sanction one of those. Vigil's own
  documentation used to argue the opposite — that a program approving itself
  had removed the gate "including for a later version of itself whose script
  has been changed" — and the second half of that was simply wrong about what
  the hash covers. The comment saying so has been replaced with the reading
  that is correct
- Every claim in the repository that Vigil never approves its own hooks has
  been corrected rather than left to contradict the product: the reasoning on
  `CodexTrustWriter`, the notes on `HookInstaller`, and the relevant paragraphs
  of DESIGN.md
- The settings window is 740 points tall, up from 712 — one switch row for the
  new setting, plus the same one-spare-notice margin as before. The worst case
  measures 708
- Existing installs read as out of date, and are brought up to date on the next
  launch with nothing to press and nothing to approve. This entry used to say
  they needed Install re-running by hand, and that Codex users would then have
  to approve the `SessionStart` entry in `/hooks` or from Vigil — which was the
  release that made the recurring cost of the trust gate impossible to ignore,
  and is the reason for the entries above it
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
- Updating Vigil updates the hook script. `~/.vigil/hooks/vigil-hook.sh` is
  copied out of the app bundle by the install, and nothing ever compared the
  installed copy against the bundled one again: every health check reads the
  hook *entries* in an agent's settings file, and none of them reads the
  script's bytes. So replacing Vigil.app with a newer version whose entries
  happened to be identical left the old script in place, still executable, still
  named by all four agents — and every fix to it after the version you installed
  reached nobody who had already installed. Vigil now replaces that file when it
  is not the one this build ships, at launch and when the panel opens, and
  restores its executable bit if it has lost one. Only that file: the entries
  already point at it, so nothing in anybody else's config is rewritten
- Installing or updating the hook script can no longer be caught half-done. It
  was removed and then copied, so an agent that fired a hook in between found no
  file at a path its settings said was there. The new copy is staged beside the
  old one and renamed over it, which is a single step
- A failed lid-closed install can no longer report success. If the installer
  script could not be compiled at all, nothing ran, no error was set, and the
  next line read that absence as a completed install — leaving no helper, no
  sudoers rule, and the switch on
- `swift run` logs under the same subsystem the app does. The fallback in
  `Vigil.swift` still said `dev.vigil.app`, so a `log show --predicate` that
  worked against the bundled app quietly returned nothing for a binary run
  outside one
- Notifications work on the second try, and on every try after it. Vigil asked
  macOS for permission once, kept the answer, and counted a *thrown* request as
  a refusal — but `requestAuthorization` throws "Notifications are not allowed
  for this application" on the first ask on a machine where nobody has answered
  the system prompt yet, which is every machine on its first run. The prompt was
  still on screen at that moment, and pressing Allow changed nothing: the answer
  had already been written down as no and was never read again. A menu bar app
  nobody quits therefore ran silent for its whole life — no completion chime, no
  run-ended alert, no guardrail warning — with one line in the unified log to say
  so. Vigil now reads the system's own record each time it has something to say
  and asks only while that record says the question is still open, so a grant
  takes effect on the next notification instead of the next launch
- `MARKETING_VERSION` could still be overridden past the `VERSION` file, and
  `Scripts/release.sh` printed that override in its own usage example. It
  produces a release that disagrees with itself in the one way nothing
  downstream can catch: the binary, the disk image's name, the changelog
  section looked up and the tag suggested at the end all follow the override,
  while the commit the tag points at — which the script has just checked is
  clean, so it is the commit anyone auditing the release will read — still says
  the old number. The override is now accepted only when it agrees with the
  file, and the usage example says to edit `VERSION`
- `Scripts/changelog-section.sh` wrote to `/tmp/vigil-notes.$$`: a guessable
  name in a directory every account on the Mac can write to, and `>` follows a
  symlink, so another local user could have pointed it at a file of this user's
  and had the script truncate it. It holds the section in a variable now —
  nothing about reading one heading out of a file needs to touch the disk.
  `release.sh`'s closing instructions wrote `/tmp/notes.md` for the same
  reason and now write into `dist/`, beside the image they describe
- `make dmg` and `Scripts/release.sh` were both writing
  `dist/Vigil-<version>.dmg`, so the ad-hoc image built to check the layout was
  indistinguishable by name from the notarized one, in the same directory,
  ready to be attached to a GitHub release. The throwaway one is now
  `-unsigned.dmg`
- The README's escape hatch was unreachable in time. "Turn off **Set up and
  update agent hooks automatically** in Settings" is the answer to "what if I
  don't want this", and the only way to reach that switch is to launch Vigil,
  which is the moment the writing happens — so the paragraph offering a choice
  was describing one nobody could make. It now says so, and gives the launch
  that really does hold everything back:
  `dist/Vigil.app/Contents/MacOS/Vigil -managesAgentHooks '<false/>'`, which is
  the same argument `make integration` relies on and whose last check exists to
  prove it still shadows the stored value
- SECURITY.md told anyone whose Mac was left with lid-close sleep disabled to
  run `./Scripts/install-clamshell.sh --uninstall`, which is a path in a
  checkout. Someone who downloads Vigil has no checkout; their copy of that
  script is inside the app bundle, and once the app is in the Trash there is no
  copy at all. Both paths are named now, along with the fact that the order
  matters
- The first signed release would have failed notarisation. `bundle.sh` signed
  with `--timestamp=none` unconditionally, and a secure timestamp is one of the
  things Apple's notary service requires — the upload comes back Invalid, and
  the next line that would have noticed is `stapler`, which says only that it
  could not find a ticket. The flag now follows `IDENTITY`: off for ad-hoc, so
  `make build` never depends on Apple's timestamp server being reachable, on
  for a real certificate. `bundle.sh` then reads the signature back and refuses
  to hand on a Developer ID build with no timestamp in it, because passing the
  right flag and the signature carrying it are two different claims
- `BUNDLE_ID` did nothing. `Makefile` and `bundle.sh` both defined it, both
  exported it, and `Resources/Info.plist` hardcoded `dev.vigil.app`, so
  `BUNDLE_ID=... make bundle` produced an app with the identifier it was told
  not to use — silently, since nothing compared the two. The plist now carries
  a `__BUNDLE_ID__` placeholder like the two version fields, and `bundle.sh`
  fails if any placeholder survives substitution: an unsubstituted identifier
  is not a cosmetic defect, it is what launchd, `UserDefaults` and
  `SMAppService` key off
- The release disk image had nowhere to drag the app to. `hdiutil create
  -srcfolder Vigil.app` makes a volume whose only item is the app, and the
  common thing to do with that window is double-click the app where it sits —
  which runs it from a read-only volume under App Translocation, so Launch at
  Login registers a path that disappears on eject and the app dies mid-run when
  the image is unmounted. Both `make dmg` and `Scripts/release.sh` now stage a
  folder holding the app and a symlink to `/Applications`, and the release
  script mounts the finished image and checks both are there
- FlyingFox's MIT notice now ships. It is statically linked into the executable
  and MIT asks for its notice in "all copies or substantial portions", so a
  notice living only in a repo the downloader never cloned does not discharge
  it. `THIRD-PARTY-NOTICES.md` is at the root and, with `LICENSE`, inside
  `Vigil.app/Contents/Resources`
- The version was written down in three places — `Makefile`, `bundle.sh` and
  `release.sh` each defaulted to `0.1.0` — and nothing compared them, so a
  release could disagree with itself about what it was. There is now a
  `VERSION` file and all three read it
- `Scripts/release.sh` no longer swallows its own last check. The final
  `spctl --assess` on the disk image ended in `|| true`, which made the one
  test for the one failure the script exists to prevent advisory. It is fatal,
  the app is assessed as well as the image, and `notarytool`'s result is read
  back and required to be `Accepted` rather than inferred from the submission
  having finished — with the notary log printed when it is not
- `Scripts/release.sh` refuses to build from a dirty or untracked working tree.
  `CFBundleVersion` comes from `git rev-list --count HEAD`, so a release cut
  over uncommitted changes states a provenance that is not true of the binary
- The release-notes command the script printed would have shipped the whole
  changelog. `sed -n '/## \[Unreleased\]/,/^## /p'` includes the *next*
  heading, and with no next heading it runs to the end of the file: against
  this changelog it selects 547 of 553 lines. `Scripts/changelog-section.sh`
  takes one version's section, and refuses if `[Unreleased]` has not been
  rolled into a version heading first
- `make integration` no longer edits the agent config files of whoever runs it.
  Hooks are installed at launch now, so the repo's own end-to-end gate was
  rewriting `~/.claude/settings.json`, `~/.codex/hooks.json`,
  `~/.codex/config.toml`, `~/.gemini/settings.json` and `~/.cursor/hooks.json`
  — and Vigil's record of which agents it had set up, which silently takes a
  real agent out of reach of automatic setup. It runs against a throwaway home
  with hook management off for that one process, and checks afterwards that it
  changed none of them
- Removing an agent's hooks removes the trust records Vigil wrote for them in
  `~/.codex/config.toml`. They were left behind and described as inert. They
  are not: the hash covers the hook entry, so reinstalling the same hooks
  re-armed the old approval and Codex was satisfied without anyone being asked
  again. Undo now puts back all three things setup wrote
- Codex approvals are bounded on the bytes of a hook command rather than on
  Swift's `==`, which is Unicode canonical equivalence. A `hooks.json` naming an
  accented home directory in a different normal form from the one Vigil writes
  was admitted as Vigil's own, and then approved under a hash Vigil never
  predicted — the one place in the path where the value compared and the value
  hashed came apart
- The "your Mac may sleep" alert no longer fires again every time a permission
  prompt is approved. Its once-per-run guard counted working sessions, and a
  prompt empties that count without ending the run. Five approvals produced five
  alerts
- A run that finishes on the same tick as a repeated guardrail warning is
  announced again. The warning's ten-minute hysteresis suppressed the warning
  and took the run ending with it, so such a run got no chime and no
  notification at all
- An automatic setup pass that fails for more than one agent explains every one
  of them, rather than only the last. The panel also no longer says "Nothing was
  changed" when a pass set three agents up and failed the fourth
- The bridge could bind a truncated socket path and report itself listening.
  `sun_path` is a fixed 104 bytes and the address builder copied into it without
  complaining, so a longer path bound successfully at a silently shortened one —
  and the hook, rebuilding the full path, would have found nothing there and
  exited 0. Every event dropped in silence, with the panel saying the bridge was
  up
- The panel no longer claims an approval that was never written: the agent was
  marked approved before the trust record was written, and not unmarked when
  that write threw
- A ledger row with a long process name could draw a single orphaned capital
  letter where its context had been squeezed below the width of an ellipsis
- Claude Code's `Notification` is registered per `notification_type` instead of
  whole. Every value mapped to "waiting", so `elicitation_complete`,
  `auth_success`, `agent_completed`, `computer_use_exit`, `push_notification`
  and the `quota_auto_resume_*` values each released the wake hold in the middle
  of a turn — long enough to sleep mid-task on a Mac whose idle timer had
  already elapsed. The five values that mean a human is being asked something
  now map to "waiting", `idle_prompt` maps to "idle", and the mid-turn values
  are not registered for at all, so they fire no hook and change no state. A
  value Claude Code adds later gets the same treatment
- Pressing escape in Claude Code ends the run about a minute later instead of
  leaving it live for the full five-minute staleness window. `idle_prompt` is
  the only thing Claude Code says after an interrupt, and it can now be read as
  the ending it is
- Codex's `SessionStart` is listened for again, narrowed to
  `startup|resume|clear|fork`. It had been dropped entirely because Codex
  re-fires it mid-turn with source `compact` after a compaction, releasing the
  hold across the slowest request in the session; the matcher excludes that one
  source, so a genuine session start is observed again without it
- An install that is both out of date and untrusted offers "Update" before "run
  /hooks". For Codex the trust record covers the entry itself, so a hook that
  changed since it was approved is both — and approving the old entry first
  would only re-arm what the update replaces
- Cursor sessions are labelled with the folder you actually have open. Cursor's
  hook payload carries no working directory at all — it sends `workspace_roots`
  — so every Cursor row showed whatever directory Cursor happened to launch the
  hook from: the same wrong path for every window on the machine. A window with
  several folders open is named after the first; one with no folder open shows
  no path rather than a made-up one
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
- The note about a host that will not run Vigil's hooks names the one thing
  left to do about it. It used to say "Trust them in Settings", matching a
  button that no longer exists; it now names the host's own review command,
  because what reaches that note is an entry Vigil did not write and will not
  approve
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
  problem. This entry used to end by saying Vigil never records the approval on
  its own, because the gate exists so that a human read the command before
  their agent ran it. It records it now, for its own entries and for nothing
  else — the entries under Changed give the reading of Codex's hash that makes
  that a narrower claim than it sounds, and the disclosure that goes with it.
  **If you set Codex up with an earlier build, nothing is needed: the next
  launch brings the entries up to date and records the approval for them.**
  Claude Code, Cursor and Gemini CLI were checked for the same gate and have
  none for the files Vigil writes
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
