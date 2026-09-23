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

# Troubleshooting: `touch /tmp/vigil-hook-debug` to trace every invocation.
# Useful for answering "is my agent actually calling this?", which is otherwise
# invisible because the hook is deliberately silent.
[ -f /tmp/vigil-hook-debug ] && \
  echo "$(date +%H:%M:%S) $AGENT $EVENT $STATE" >> /tmp/vigil-hook.log

SOCKET="$HOME/Library/Application Support/Vigil/bridge.sock"
[ -S "$SOCKET" ] || exit 0

# Read the host's JSON payload, if it sends one.
#
# `INPUT=$(cat)` waits for EOF, so a host that hands the hook its own stdin and
# never closes it hung here forever — inside the user's agent, on their
# critical path.
#
# A line at a time with a timeout on each, rather than one timed read of the
# whole thing: macOS ships bash 3.2, which throws away partial input when a
# read times out, so a single read would lose the entire payload against a host
# that simply left the pipe open. Per line, the timeout only costs the last
# line that never arrives. A JSON string cannot contain a raw newline, so
# rejoining the lines with nothing between them is safe.
#
# One case still degrades: a host that writes its payload with no trailing
# newline *and* holds the pipe open loses it, because bash 3.2 discards the
# partial line. The event is still posted — keyed on the parent pid, which is
# stable for the life of that host process — so the session is tracked, just
# without its title and cwd. Better than the alternative, which was to hang.
INPUT=""
if [ ! -t 0 ]; then
  line=""
  while IFS= read -r -t 1 line || [ -n "$line" ]; do
    INPUT="$INPUT$line"
    line=""
    # A hook payload is a few hundred bytes. Anything past this is a bug or a
    # probe, and Vigil's socket would refuse it anyway.
    [ "${#INPUT}" -gt 65536 ] && break
  done
fi

# plutil parses JSON safely and is on every Mac; jq is not.
extract() { printf '%s' "$INPUT" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null || true; }

SESSION_ID=$(extract session_id)
[ -z "$SESSION_ID" ] && SESSION_ID=$(extract sessionId)
CWD=$(extract cwd)
[ -z "$CWD" ] && CWD="$PWD"

# First line of the prompt, capped.
#
# `head -c 200` cut at a byte, which splits a multibyte character: BSD sed then
# refused the whole string with "illegal byte sequence", and even under LC_ALL=C
# the half-character made the JSON body invalid UTF-8, so Vigil rejected the
# event entirely rather than merely losing the title. iconv -c drops whatever
# does not survive the cut, so what we send is always valid UTF-8.
TITLE=$(extract prompt | head -n 1)
TITLE=$(printf '%s' "${TITLE}" | head -c 400 | /usr/bin/iconv -c -f UTF-8 -t UTF-8 2>/dev/null)

# Escape for embedding in JSON, and strip control characters that would make
# the payload invalid. Byte-wise (LC_ALL=C) throughout: sed errors out on input
# its locale considers malformed, and a hook that fails is a hook that reports
# nothing.
escape() {
  printf '%s' "$1" | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g' | LC_ALL=C tr -d '\000-\037'
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
