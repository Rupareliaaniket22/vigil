# Vigil — Product Requirements

*Draft, 23 September 2026. Written against research on the competitive field and
the macOS platform constraints; two user-research threads were still open when
this was drafted and may revise §2 and §7.*

---

## 1. The problem

An AI coding agent working through a long task produces no keyboard or mouse
input. macOS sees an idle machine and sleeps it. The run dies.

The existing fix is a blunt one: keep-awake tools that never let the Mac sleep
until you remember to turn them off. People forget, and a laptop that cannot
sleep runs hot in a bag and flattens its battery overnight. So the real problem
is not "keep my Mac awake" — it is **keep my Mac awake exactly as long as
something is actually working, and not one minute longer.**

### Why now

Agentic coding tools that run unattended for minutes at a time are new. The
keep-awake category predates them by fifteen years and was designed for a human
watching a download finish.

## 2. Who it is for

Developers running Claude Code, Codex, Cursor or similar on a MacBook, who start
a task and walk away. They are technically literate, care what runs on their
machine with elevated privileges, and are the population most likely to read the
source before installing.

**Not for:** people who want a general keep-awake toggle. Amphetamine is free,
excellent, and better at that.

## 3. What it must do

### Must have — a v1 is not credible without these

| | Requirement | Status |
| --- | --- | --- |
| R1 | Hold a wake lock only while an agent is actively working | ✅ done |
| R2 | Release it promptly when all agents stop | ✅ done |
| R3 | Survive a crashed or killed agent without pinning the Mac awake forever | ✅ done — sessions expire |
| R4 | Stop at a battery floor, whatever agents are doing | ✅ done |
| R5 | Never interfere with the agent it watches | ✅ done — hook is fail-open |
| R6 | Restore normal sleep on quit | ✅ done |
| R7 | Work with Claude Code out of the box | ✅ done |
| R8 | Explain why the Mac is or isn't awake | ✅ done |

### Should have

| | Requirement | Status |
| --- | --- | --- |
| R9 | Keep working with the lid closed | ✅ done — needs one-time setup |
| R10 | Notify when a run finishes | ✅ done, delivery unverified |
| R11 | Warn when a guardrail cuts a run short | ✅ done |
| R12 | Mains-only and Low Power Mode respect | ✅ done |
| R13 | Launch at login | ✅ done |
| R14 | Support Codex, Cursor, Gemini, OpenCode | ⬜ recognised, no hooks shipped |
| R15 | Signed, notarized release | ⬜ blocked on a Developer ID |
| R16 | Auto-update | ⬜ not started |

### Explicitly out of scope

- **A general keep-awake timer.** "Keep awake for 2 hours" is Amphetamine's job.
- **Remote or multi-machine monitoring.** Different product.
- **Anything that reads code or terminal output.** Vigil sees lifecycle events
  and nothing else. This is a promise, not an omission.
- **iOS, iPadOS, Linux.** The whole mechanism is macOS power management.

## 4. Principles

1. **Do nothing when nothing is running.** The app's best state is invisible
   and inert.
2. **A guardrail always wins.** No amount of agent activity or manual override
   beats a flat battery. Enforced in `WakePolicy` before intent is considered.
3. **Never hurt the host.** A hook that hangs stalls someone's agent. Fail open,
   always.
4. **Explain, don't just act.** Every state names its reason in the user's
   words.
5. **Earn the privilege.** The normal path needs none. The one privileged
   component is small enough to audit in an afternoon.

## 5. How it works

```
agent hooks ──▶ unix socket ──▶ SessionStore ──▶ WakePolicy ──▶ decision
                                                                   │
                                            ┌──────────────────────┴───────┐
                                            ▼                              ▼
                                     IOPMAssertion                 ClamshellBackend
                                    (no privileges)                 (scoped sudo)
```

The decision is a pure function of sessions, power conditions and settings.
Everything testable is tested; everything privileged is isolated.

## 6. What we are betting on

Three assumptions this product rests on. If any is wrong, it matters.

**A. People actually hit this.** If macOS rarely sleeps mid-run in practice,
there is no product. *Being checked.*

**B. Claude Code's own `caffeinate` doesn't already solve it.** Claude Code runs
a sleep inhibitor. If that covers most cases, Vigil's value narrows to
lid-closed operation and multi-agent coverage. *Being checked — this is the
biggest risk to the premise.*

**C. Free and auditable beats polished and paid.** Hold My Lid is $9.99, works,
and is well made. We are betting that a population who runs coding agents will
prefer a tool they can read — particularly one asking for sudo. *Unvalidated.*

## 7. Where we can genuinely win

Honestly assessed, not as a pitch:

- **The assertion ledger.** Showing every process holding the Mac awake, not
  just ours, including when the answer isn't us. Nothing else does this, it is
  ~30 lines, and it is the kind of honesty that earns trust.
- **Auditability.** For a tool requesting a sudoers rule, being readable is a
  feature, not a licence choice.
- **Correct multi-agent behaviour.** The session model handles concurrent
  agents properly. Several competitors are single-session toggles.

### Where we lose

- **Polish and support.** A paid product with one owner will out-finish a
  side project.
- **Install experience.** Without a Developer ID it is eight steps past a
  malware warning, and Homebrew banned unsigned casks in September 2026.
- **Breadth today.** Hold My Lid ships thirteen agent integrations; we ship one.

## 8. Success

This is a side project, so success is modest and honest:

- It reliably does its job on the maintainer's machine for a month without a
  stuck-awake incident.
- Someone other than the author installs it and reports it worked.
- No security issue in the privileged path.

Stars are not a goal. A single "this cooked my laptop in my bag" report would be
a failure worth stopping for.

## 9. Open questions

1. Does Claude Code's built-in `caffeinate` already cover the common case?
2. Is lid-closed the feature people actually want, or a niche want?
3. Is the $99/year for a Developer ID worth it before knowing anyone wants this?
4. Should the ledger let you *release* another app's assertion, or only show it?
   Showing is safe; acting on it is a much bigger product.
