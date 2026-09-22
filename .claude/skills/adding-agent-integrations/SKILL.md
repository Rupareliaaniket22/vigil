---
name: adding-agent-integrations
description: Wires a new AI coding agent into Vigil's bridge — mapping that agent's lifecycle events onto Vigil's working/waiting/idle model and writing a fail-open hook script that posts to the Unix socket.
when_to_use: Use when adding support for a new coding agent (Codex, Cursor, Gemini, OpenCode, Aider), editing anything under hooks/, or extending AgentKind in Sources/VigilCore/AgentEvent.swift.
---

# Adding an agent integration

`AgentKind` names five agents; only Claude Code has a working hook. Each new one
is its own small research problem, because every agent exposes a different
lifecycle vocabulary, and the failure modes are quiet ones.

## The rule that matters most: the hook must never hurt its host

A hook runs inside the user's coding agent, on their critical path. If it hangs,
their agent hangs. If it errors loudly, they blame the agent, not us.

So `hooks/claude-code/vigil-hook.sh` ends in `exit 0` unconditionally, bails
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

## 2. Write the hook

Copy `hooks/claude-code/vigil-hook.sh` and adapt it. The contract:

- Exit 0 on every path.
- Return early unless the socket exists.
- Parse the agent's payload with `plutil` — `jq` is not on a stock Mac.
- Escape JSON by hand; a prompt containing a quote must not produce invalid JSON.
- POST to `http://localhost/event` via `curl --unix-socket`, with the timeouts above.

The body must match `AgentEvent`'s `CodingKeys` — note `session_id`, not
`sessionID`:

```json
{"agent":"codex","session_id":"…","state":"working",
 "event":"…","pid":123,"cwd":"…","title":"…"}
```

Only `agent`, `session_id` and `state` are required. A missing session id or an
unrecognised state is rejected with 400 rather than guessed at.

## 3. Add the AgentKind constant

Only if the agent isn't already in `AgentEvent.swift`. Unknown agents are
accepted at runtime by design, so a new tool works before we ship a release —
the constant is for our own call sites, not a gate.

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
`log stream --predicate 'subsystem == "dev.vigil.app"' --level debug`.

## Before you're done

- Hook exits 0 on every path, including parse failure
- Timeouts present on the curl call
- A prompt containing `"` and `\` still produces valid JSON
- Blocked-on-user events map to `waiting`
- Manual curl test shows the assertion taken and released
- `make test && make lint` pass
