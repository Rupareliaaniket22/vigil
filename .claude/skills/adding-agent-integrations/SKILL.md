---
name: adding-agent-integrations
description: Wires a new AI coding agent into Vigil's bridge — mapping that agent's lifecycle events onto Vigil's working/waiting/idle model and writing a fail-open hook script that posts to the Unix socket.
when_to_use: Use when adding support for a new coding agent (Codex, Cursor, Gemini, OpenCode, Aider), editing anything under hooks/, or extending AgentKind in Sources/VigilCore/AgentEvent.swift.
---

# Adding an agent integration

Claude Code, Codex and Gemini CLI ship. Adding another is mostly a research
problem — every host names its lifecycle events differently — and then one
constant.

**You almost certainly do not need to write a shell script.** The event-to-state
mapping is baked into the installed command (`vigil-hook.sh <agent> <event>
<state>`), so one script serves every agent and the mapping lives in
`AgentIntegration.swift` where it is typed and tested.

## The rule that matters most: the hook must never hurt its host

A hook runs inside the user's coding agent, on their critical path. If it hangs,
their agent hangs. If it errors loudly, they blame the agent, not us.

So `hooks/vigil-hook.sh` ends in `exit 0` unconditionally, bails
immediately when the socket is absent, and caps curl at
`--connect-timeout 0.25 --max-time 1`. Those aren't stylistic choices — they're
the difference between a utility and a liability. Keep them in any new hook.

## 1. Learn the agent's real event names

Don't guess them. Find the agent's hook or plugin documentation and list the
events it actually emits, then map each onto Vigil's three states.

Claude Code, as the worked example:

| Their event | Vigil state |
| ----------- | ----------- |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop` | `working` |
| `Notification` | `waiting` |
| anything else, including `SessionEnd` | `idle` |

The judgement call in every mapping is which events mean *blocked on the human*.
Those must map to `waiting`, not `working` — an agent sitting on a permission
prompt could wait for hours, and holding the Mac awake through that is exactly
the battery-drain behaviour Vigil exists to avoid.

A good place to find a host's real event names is its own config file on a
machine where a competing tool has already integrated — `~/.codex/hooks.json`
and `~/.gemini/settings.json` are how Codex's and Gemini's vocabularies were
established, rather than by guessing.

## 2. Add the constant

In `AgentIntegration.swift`, and append it to `.all`:

```swift
public static let cursor = AgentIntegration(
  id: .cursor,
  displayName: "Cursor",
  settingsPath: ".cursor/hooks.json",
  workingEvents: [...],
  waitingEvents: [...],   // blocked on the user
  idleEvents: [...],
  timeoutMilliseconds: nil // only if that host's config expects one
)
```

Add an `AgentKind` constant too if it is genuinely new. Unknown agents are
accepted at runtime by design, so a new tool works before we ship a release —
the constant is for our own call sites, not a gate.

Anything not listed maps to idle. That default is deliberate: guessing "working"
would let a mislabelled hook pin the Mac awake indefinitely.

## 3. Register it with the host

Each host has its own mechanism for trusting a hook. Codex records a
`trusted_hash` per hook in `config.toml`, so a newly installed hook may need
approving on first run. Read the host's documentation; don't assume it behaves
like Claude Code.

## 4. Verify without installing the agent

The whole path is testable by hand:

```sh
SOCK="$HOME/Library/Application Support/Vigil/bridge.sock"

curl --unix-socket "$SOCK" -X POST http://localhost/event \
  -d '{"agent":"codex","session_id":"t1","state":"working"}'
pmset -g assertions | grep -i vigil        # expect a held assertion

curl --unix-socket "$SOCK" -X POST http://localhost/event \
  -d '{"agent":"codex","session_id":"t1","state":"idle"}'
sleep 6
pmset -g assertions | grep -i vigil        # expect nothing
```

Then run the real agent once and confirm the events arrive:
`log stream --predicate 'subsystem == "io.github.rupareliaaniket22.vigil"' --level debug`.

## Before you're done

- Hook exits 0 on every path, including parse failure
- Timeouts present on the curl call
- A prompt containing `"` and `\` still produces valid JSON
- Blocked-on-user events map to `waiting`
- Manual curl test shows the assertion taken and released
- `make test && make lint` pass
