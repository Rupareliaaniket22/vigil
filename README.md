<div align="center">

<img src="Resources/mark.png" width="120" alt="Vigil">

# Vigil

**Your Mac stays awake while your agents work. Not a minute longer.**

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-1C1C1E?style=flat-square)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-FFB340?style=flat-square)](https://swift.org)
[![Apache 2.0](https://img.shields.io/badge/licence-Apache--2.0-1C1C1E?style=flat-square)](LICENSE)
[![113 tests](https://img.shields.io/badge/tests-113-FFB340?style=flat-square)](Tests)

</div>

---

You start Claude Code on something long and walk away. It runs for eleven
minutes without touching the keyboard, macOS decides you've gone, and the
machine sleeps. The run dies somewhere in the middle.

The usual fix is a keep-awake app you switch on and forget to switch off. Then
your laptop spends the night at full tilt in a bag.

**Vigil holds the wake lock only while an agent is actually mid-task**, and lets
go the moment it stops.

```
  Keeping your Mac awake                      ▁▃▅ 67%
  2 agents working

  Agents
  ●  Claude Code    ~/code/vigil                    4m
  ●  Codex          ~/code/api                      1m
  ○  Gemini CLI                                   idle

  Also holding your Mac awake
     Your display is on     powerd              1h 38m
```

## The part nothing else does

That last section is a **live readout of every process holding your Mac awake** —
not just Vigil's. When something else is the reason, it says so.

It was checked against roughly twenty competing tools, reading the source of the
two closest. None of them ship it. The nearest equivalent is a support page
teaching you to run `pmset -g assertions` in Terminal.

It found a stray twelve-hour `caffeinate` on the author's machine within a minute
of being built.

## Guardrails

A keep-awake tool that never lets go is a fire hazard. Every one of these
outranks the agents, and the first outranks everything:

| | |
| --- | --- |
| **Heat** | Releases when the Mac runs hot, on mains power too. Beats a manual hold — a Mac held awake in a closed bag has nowhere to put it |
| **Battery floor** | Stops below a charge you set, and actually asks the Mac to sleep rather than merely permitting it |
| **Mains only** | Optional: never hold on battery |
| **Low Power Mode** | Respected |
| **Dead agents** | A session that stops reporting expires, so a crashed agent can't pin your Mac awake |

## Install

Requires macOS 14 or later. No Xcode needed — Command Line Tools is enough.

```sh
git clone https://github.com/Rupareliaaniket22/vigil
cd vigil
make run
```

Click the icon in your menu bar, then **Set up**. Vigil finds the agents you have
installed, adds a hook to each one's settings, and keeps a backup of every file
it touches. Other tools' hooks are left alone.

Press **⌥⌘L** anywhere to hold your Mac awake regardless.

## Supported agents

**Claude Code** · **Codex** · **Gemini CLI** · **Cursor**

Each reports through its own lifecycle hooks, so Vigil knows the difference
between an agent working and a terminal sitting open. Adding another is a
constant in `AgentIntegration.swift` — one script serves them all.

## Working with the lid closed

Off by default. Turning it on asks for your password once, because keeping a Mac
awake with the lid shut means changing a system setting that needs root.

Vigil installs a small root-owned helper that can change **that one setting and
nothing else** — no wildcards, no shell, three fixed arguments. The installer
refuses outright unless every directory on the path to it is root-owned.

[SECURITY.md](SECURITY.md) has the threat model. Read it before you turn this on.

## How it works

```
  agent hooks ──▶ unix socket ──▶ SessionStore ──▶ WakePolicy
                                                       │
                                  ┌────────────────────┴───────┐
                                  ▼                            ▼
                           IOPMAssertion              root helper
                          (no privileges)            (opt-in only)
```

The wake lock itself needs no privileges — the same mechanism `caffeinate` uses.
Only lid-closed operation touches root, and it's isolated behind one protocol.

A Unix socket rather than a localhost port, because `127.0.0.1` is reachable by
every other user account on the machine.

The decision is a pure function of sessions, power state and settings. Everything
testable lives in `VigilCore` with an injected clock.

## Not done yet

- **No signed release.** Build from source for now; a Developer ID is £99/year and this is a side project
- **No auto-update**
- **OpenCode** uses a JavaScript plugin rather than shell hooks — a different mechanism

## Build

```sh
make build            # debug
make test             # 113 tests
make lint             # swift-format, strict
make smoke            # builds the real panel headlessly
make integration      # drives a live app and checks macOS's power state follows
make bundle           # universal, signed .app
```

See [CONTRIBUTING.md](CONTRIBUTING.md), [AGENTS.md](AGENTS.md) for conventions,
and [DESIGN.md](DESIGN.md) for the visual contract.

## Licence

[Apache 2.0](LICENSE).
