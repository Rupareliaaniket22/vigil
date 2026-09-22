# Implementation plan

Where Vigil stands and what comes next, in order. Each step is small enough to
finish and verify in one sitting, and leaves the tree green.

*Updated 23 September 2026.*

---

## Done

| Step | What | Verified by |
| --- | --- | --- |
| 1 | Wake decision, session tracking, event parsing | 37 unit tests |
| 2 | Unprivileged `IOPMAssertion` hold and release | live — assertion taken and released |
| 3 | Unix-socket bridge for agent hooks | live — two agents, correct counting, 400 on malformed input |
| 4 | Menu bar app, panel, settings window | `make smoke` builds the real panel |
| 5 | Hook install into Claude Code settings | `make smoke` runs a full install/uninstall cycle |
| 6 | Notifications on completion and guardrail cut | rules unit-tested; delivery needs a human |
| 7 | Lid-closed support via a scoped sudoers helper | hostile input rejected; needs sudo to run for real |
| 8 | Universal build, ad-hoc signing, release script | `make bundle`; release script unproven |
| 9 | Docs, skills, generated icon | — |
| 10 | Thermal ceiling | unit tests; heat outranks every other rule |
| 11 | Codex and Gemini CLI integrations | 48 unit tests; hook verified posting live |
| 12 | Global shortcut (⌥⌘L) | registers without conflict |
| 13 | Clamshell drift reconciliation | unprivileged IOPMrootDomain read verified |
| 14 | Crash and signal safety | SIGTERM path verified |
| 15 | `make integration` — 16 live checks | all passing |
| 16 | Cursor integration (a different entry shape) | 56 unit tests |
| 17 | Guardrail-forced sleep request | rules unit-tested; helper verified |
| 18 | Bridge failure surfaced in the UI | recovery verified; error path not |

## Next

### 19. Verify the things only a human can verify

Nothing here is code. It is the gap between "builds" and "works".

- Click the menu bar icon; confirm the panel looks like DESIGN.md intends.
- Click **Set up Claude Code**, then run an agent and watch sessions appear.
- Confirm a notification actually arrives when a run finishes.
- `sudo ./Scripts/install-clamshell.sh`, enable lid-closed, shut the lid with
  an agent running, and confirm it keeps going — then confirm it stops when the
  battery floor is reached.

**Do this before building anything else.** Every step below assumes the core
loop is sound, and that is currently an assumption.

### 20. OpenCode

The one remaining named agent, and the awkward one: OpenCode uses a JavaScript
plugin rather than shell hooks, so it needs a different delivery mechanism from
the other four. Its event stream is `session.status`, `message.part.updated`
and `session.deleted` rather than named lifecycle hooks.

### 21. An AC-to-battery test with the lid shut

Two more mature implementations have open bugs here, so it is a known-hard
case. Vigil reconciles against `IOPMrootDomain` rather than a cached belief,
which should handle it, but that is reasoning, not evidence. Needs someone to
unplug a laptop with the lid closed and an agent running.

### 22. Display-off control

Let the screen sleep while the system stays up. This is the overnight case:
people want the agent to keep working and the room to be dark. Currently the
assertion already permits display sleep, so this is about making it explicit
and configurable rather than incidental.

### 23. Auto-update

Sparkle 2.10, EdDSA appcast on GitHub Pages. Only worth doing once there is a
signed release to update *to* — until then it has nothing to install.

## Blocked

| Item | Blocked on | Note |
| --- | --- | --- |
| Signed, notarized release | A $99/yr Developer ID | `Scripts/release.sh` is written and waiting |
| `SMAppService` privileged helper | The same Developer ID | Registration silently fails without a matching Team ID — this is why the sudoers path exists |
| Homebrew cask | A signed release | Homebrew banned unsigned casks in September 2026 |

## Deliberately not doing

- **A general keep-awake timer.** Amphetamine is free and better at it.
- **Releasing other apps' assertions from the ledger.** Showing them is safe;
  acting on them is a much larger product with a real blast radius.
- **An onboarding carousel.** The panel explains itself.
- **XcodeGen or an `.xcodeproj`.** Building with Command Line Tools alone is a
  contributor benefit worth protecting.

## The rule for every step

`make test && make lint && make smoke` all pass before committing. A step that
cannot be verified is not finished — and if something cannot be verified in
this environment, say so in the commit rather than implying it works.
