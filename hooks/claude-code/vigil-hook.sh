#!/bin/bash
#
# Vigil's hook. One script for every agent.
#
#   vigil-hook.sh <agent> <event> <state>
#
# The event-to-state mapping is decided at install time and baked into the
# command, so this script does not need to know one agent's vocabulary from
# another's — and the mapping stays in Swift where it is typed and tested.
#
# Exits 0 on every path. This runs inside someone's coding agent, on their
# critical path: if it hangs or fails loudly, they blame the agent.
set -u

AGENT="${1:-unknown}"
EVENT="${2:-unknown}"
STATE="${3:-idle}"

SOCKET="$HOME/Library/Application Support/Vigil/bridge.sock"
[ -S "$SOCKET" ] || exit 0

INPUT=$(cat 2>/dev/null || true)

# plutil parses JSON safely and is on every Mac; jq is not.
extract() { printf '%s' "$INPUT" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null || true; }

SESSION_ID=$(extract session_id)
[ -z "$SESSION_ID" ] && SESSION_ID=$(extract sessionId)
CWD=$(extract cwd)
[ -z "$CWD" ] && CWD="$PWD"
TITLE=$(extract prompt | head -c 200)

# Escape for embedding in JSON, and strip control characters that would make
# the payload invalid.
escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | LC_ALL=C tr -d '\000-\037'
}

PAYLOAD=$(printf '{"agent":"%s","session_id":"%s","state":"%s","event":"%s","pid":%d,"cwd":"%s","title":"%s"}' \
  "$(escape "$AGENT")" \
  "$(escape "${SESSION_ID:-pid-$PPID}")" \
  "$(escape "$STATE")" \
  "$(escape "$EVENT")" \
  "${PPID:-0}" \
  "$(escape "$CWD")" \
  "$(escape "$TITLE")")

# Synchronous, but bounded. Some hosts reap the process group on exit, which
# would kill a backgrounded curl before it reached the socket. A local socket
# connects in under a millisecond or refuses instantly, so this never
# meaningfully delays the agent.
/usr/bin/curl -sS --unix-socket "$SOCKET" \
  --connect-timeout 0.25 --max-time 1 -o /dev/null \
  -X POST "http://localhost/event" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" >/dev/null 2>&1

exit 0
