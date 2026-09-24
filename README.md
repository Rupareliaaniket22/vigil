<div align="center">

<img src="Resources/mark.png" width="180" alt="Vigil">

# Vigil

**Keeps your Mac awake while your AI agents work.**
Not a minute longer.

<br>

[![Platform](https://img.shields.io/badge/platform-macOS-1C1C1E?style=flat-square)](https://www.apple.com/macos/)
[![Requirements](https://img.shields.io/badge/requires-macOS%2014%2B-FFB340?style=flat-square)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-FFB340?style=flat-square)](https://swift.org)
[![Tests](https://img.shields.io/badge/tests-420-1C1C1E?style=flat-square)](Tests)
[![License](https://img.shields.io/github/license/Rupareliaaniket22/vigil?style=flat-square&color=1C1C1E)](LICENSE)

</div>

<br>

```
  Keeping your Mac awake                      ▁▃▅ 67%
  2 agents working

  Agents
  ●  Claude Code    ~/code/vigil                    4m
  ●  Codex          ~/code/api                      1m
  ○  Gemini CLI                                   idle
  ○  Cursor                                       idle

  Also holding your Mac awake
     Your display is on     powerd              1h 38m

  ───────────────────────────────────────────────────
  Always keep awake                              ( ●)
  Pause 30 minutes
  Settings…                                       ⌘,
```

<br>

Vigil is a menu bar app that holds your Mac awake while a coding agent is
actually working, and lets it sleep again the moment that stops. It reads the
lifecycle hooks your agents already expose, so it knows the difference between a
run in progress and a terminal left open.

> [!NOTE]
> Vigil is early. It works, and it's tested, but there's no signed release yet —
> build it from source for now. See [Not done yet](#not-done-yet).

## Install

> [!IMPORTANT]
> **Vigil wires your agents up the moment it launches, without asking** — and
> the command below is that moment, not a later click. Read this first.
>
> On launch, Vigil looks for Claude Code, Codex, Gemini CLI and Cursor and
> writes a hook into the config of each one it finds:
> `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.gemini/settings.json`,
> `~/.cursor/hooks.json`. Codex runs no hook it has not approved, so Vigil also
> writes a trust record for its own entries into `~/.codex/config.toml`.
>
> Every file is copied to `<file>.vigil-backup` before its first edit, nothing
> else in it is changed, and a file Vigil cannot parse is left alone rather than
> rewritten. The menu bar panel says which agents it set up and offers
> **Undo**, which takes the hooks, the shared script and the trust record back
> out.
>
> To decide for yourself instead, turn off **Set up and update agent hooks
> automatically** in Settings. Nothing is then written until you press
> **Set up** on an agent.

```sh
git clone https://github.com/Rupareliaaniket22/vigil
cd vigil
make run
```

Requires macOS 14 or later. No Xcode needed — Command Line Tools is enough.

Open the menu bar icon and you should see your agents listed. [SECURITY.md](SECURITY.md#writing-into-other-programs-config-files)
has the full account of what gets written and what bounds it.

## Features

- **Holds only while work is happening.** Reads real lifecycle hooks from
  **Claude Code**, **Codex**, **Gemini CLI** and **Cursor**
- **Shows everything keeping your Mac awake** — not just its own hold. When
  another app is the reason, it says so, and for how long
- **Stops before your Mac does** — heat, battery floor, mains-only and Low Power
  Mode all outrank the agents
- **Works with the lid closed**, if you want it to
- **Tells you when a run finishes**, and warns if one is cut short
- **⌥⌘L** from anywhere to hold your Mac awake regardless

## Guardrails

A keep-awake tool that never lets go is a fire hazard, so these come first:

| | |
| :-- | :-- |
| **Heat** | Releases when your Mac runs hot — on mains power too, and it beats a manual hold |
| **Battery** | Stops below a charge you choose, and asks your Mac to sleep rather than merely allowing it |
| **Mains only** | Optional: never hold on battery |
| **Low Power Mode** | Respected |
| **Crashed agents** | A session that stops reporting expires, so it can't pin your Mac awake |

## Working with the lid closed

Off by default. Turning it on asks for your password once, because changing
lid-close behaviour needs root.

Vigil installs a small root-owned helper that can change **that one setting and
nothing else** — three fixed arguments, no shell, no wildcards. The installer
refuses unless every directory on the path to it is root-owned.

[SECURITY.md](SECURITY.md) has the full threat model.

## How it works

The wake lock itself needs no privileges — it's the same mechanism `caffeinate`
uses. Agent hooks post to a Unix socket in your home directory, a pure function
decides whether to hold, and only lid-closed operation touches root.

A Unix socket rather than a localhost port, because `127.0.0.1` is reachable by
every other user account on the machine.

## Not done yet

- **No signed release.** Build from source for now
- **No auto-update**
- **OpenCode** uses a JavaScript plugin rather than shell hooks
- **Desktop apps other than Cursor.** Claude and ChatGPT desktop publish no
  lifecycle events and hold no wake lock of their own, so Vigil cannot see
  them working. It will not guess: an idle window and one waiting on the
  model look the same from outside

## Building

```sh
make test             # unit tests
make lint             # swift-format, strict
make smoke            # builds the real panel headlessly
make integration      # drives a live app, checks macOS's power state follows
make bundle           # universal, signed .app
```

`make integration` launches Vigil against a throwaway home directory, so it
sets up no agents and touches none of your own config — and it checks that it
did not, rather than assuming.

[CONTRIBUTING.md](CONTRIBUTING.md) · [AGENTS.md](AGENTS.md) · [DESIGN.md](DESIGN.md)

## License

[Apache 2.0](LICENSE)
