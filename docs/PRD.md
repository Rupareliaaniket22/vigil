# Vigil — Product Requirements

*Draft, 23 September 2026. Revised the same night after competitive research
came back and showed §7 was wrong.*

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
| R11a | Release the hold when the Mac runs hot | ✅ done |
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

## 7. The competitive picture

The field is more crowded than it first appeared, and **the real competition is
not the paid apps.** A free tool competes with better free tools, and two exist:

| | Stars | Agents | Thermal | Battery floor | Ledger |
| --- | --- | --- | --- | --- | --- |
| **Adrafinil** (MIT) | 480 | 9, hooked | ✅ | ❌ | ❌ |
| **coffee-bar** (Apache-2.0) | 13 | 1, hooks-only | ❌ | ✅ 15% | ❌ |
| **Vigil** | 0 | 1 shipped | ✅ | ✅ 20% | ✅ |

coffee-bar is close to an architectural twin — same licence, Unix-socket hook
bridge, unprivileged assertion, session tracking. Adrafinil is three months
ahead with nine agents, reference-counted sessions and an MCP surface.

At least ten people independently built a version of this in 2026. Most got
single-digit stars and went quiet within days.

### Where we genuinely win

- **The assertion ledger.** Checked against roughly twenty products, including
  source-level reads of the two closest analogs. **Nothing else has it.**
  Perked publishes a support page teaching users to run `pmset -g assertions`
  in Terminal rather than shipping the feature. This is the product's reason to
  exist, not a panel section.
- **Guardrail completeness.** Thermal + battery floor + mains-only + Low Power
  Mode together. Adrafinil, the 480-star leader, has thermal and none of the
  other three.
- **Reach.** macOS 14+ against Adrafinil's macOS 26+, and a Command-Line-Tools
  build against its Xcode 26 requirement.

### Where we lose

- **No signed release, no auto-update.** Every serious competitor gets a user
  to a running app faster than we do.
- **Agent breadth.** One shipped against Adrafinil's nine. An agent-agnostic
  protocol is a design affordance, not a delivered feature.
- **Zero users.** Against a field with a 480-star and a 184-star entrant.

### The honest case against building this

The strongest version: the core mechanism is well-understood enough that ten
people built it this year, and two abandoned repos accumulated 57 and 62 stars
respectively *despite being abandoned within hours of creation* — which
suggests people are starring the idea, not adopting a tool.

**Our two best differentiators would plausibly have more real-world impact as
pull requests against coffee-bar** — same licence, already shipped, already has
users — than as a nineteenth competing menu bar app starting from zero.

The fair counter: nobody has the ledger, our guardrails are more complete than
the category leader's, Adrafinil's macOS 26 floor is a real exclusion ours
isn't, and the work is done and tested. As a well-engineered personal tool and
a credible piece of public work, that is sufficient. As a bid for adoption, it
is late.

### If it proceeds, the position is narrow

Not "the open-source agent-aware keep-awake app" — that is taken twice, by
tools with more stars and more agents. Instead:

> **The one that tells you the truth about why your Mac is awake, and that you
> can audit before you give it root.**

That means shipping a signed release before polishing anything else, and
treating the ledger as the reason the product exists.

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
5. Does an AC-to-battery transition while lid-closed is armed behave correctly?
   Lidless has two open bugs about exactly this and Amphetamine shipped a whole
   component to fix it, so it is a known-hard case we have not tested.
6. Would these differentiators do more good as PRs to coffee-bar?
