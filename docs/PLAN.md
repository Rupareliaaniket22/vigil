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

## Next

### 10. Verify the things only a human can verify

Nothing here is code. It is the gap between "builds" and "works".

- Click the menu bar icon; confirm the panel looks like DESIGN.md intends.
- Click **Set up Claude Code**, then run an agent and watch sessions appear.
- Confirm a notification actually arrives when a run finishes.
- `sudo ./Scripts/install-clamshell.sh`, enable lid-closed, shut the lid with
  an agent running, and confirm it keeps going — then confirm it stops when the
  battery floor is reached.

**Do this before building anything else.** Every step below assumes the core
loop is sound, and that is currently an assumption.

### 11. A second agent integration

Codex or Cursor. Follow `.claude/skills/adding-agent-integrations`. The
blocker is research, not code: each agent exposes a different lifecycle
vocabulary and it has to be read, not guessed.

Worth doing because "works with one agent" is a demo and "works with the ones I
use" is a tool.

### 12. Global shortcut

⌥⌘L to toggle the manual hold. Carbon's `RegisterEventHotKey` needs no
Accessibility permission, which matters — a keep-awake utility asking for
Accessibility would rightly make people suspicious.

### 13. Display-off control

Let the screen sleep while the system stays up. This is the overnight case:
people want the agent to keep working and the room to be dark. Currently the
assertion already permits display sleep, so this is about making it explicit
and configurable rather than incidental.

### 14. Auto-update

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
