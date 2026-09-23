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
#
# `-L` because /tmp is world-writable and `>>` follows a symlink: any other
# account on the Mac could point that name at a file of yours and have your
# agent append to it. `-f` is no defence — it follows the link too.
[ -f /tmp/vigil-hook-debug ] && [ ! -L /tmp/vigil-hook.log ] && \
  echo "$(date +%H:%M:%S) $AGENT $EVENT $STATE" >> /tmp/vigil-hook.log

# Disarm a Cursor permission hook left behind by an older install.
#
# Cursor reads stdout for a verdict on these four, and treats anything it cannot
# parse — empty output included — as a block. Vigil no longer registers on them
# for exactly that reason, but an entry written by a previous version is still
# sitting in somebody's hooks.json right now, blocking every shell command they
# run, and it stays there until they reinstall. Answering costs nothing and ends
# that the moment this script is updated. Printed first: whatever else goes
# wrong below, Cursor has its answer.
#
# Not a general "always allow" — the four names are spelled out, so this can
# never accidentally start voting on a hook Vigil does register for.
if [ "$AGENT" = cursor ]; then
  case "$EVENT" in
    beforeShellExecution|beforeReadFile|beforeMCPExecution) printf '{"permission":"allow"}' ;;
    beforeSubmitPrompt) printf '{"continue":true}' ;;
  esac
fi

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
#
# stderr on the read is discarded because a host that hands the hook a *closed*
# stdin gets past `[ -t 0 ]` and makes bash print "read error: 0: Bad file
# descriptor". Harmless, and the one thing this script is not allowed to be is
# noisy inside someone's agent.
INPUT=""
if [ ! -t 0 ]; then
  # Collected into an array and joined once at the end.
  #
  # Appending to a string a line at a time is quadratic in bash, and asking
  # `${#INPUT}` for the running total is quadratic again — it re-counts the
  # whole payload on every line. Together they cost 22 seconds on an 80KB
  # pretty-printed payload, spent inside the user's agent, which is the exact
  # failure the top of this file says must not happen. The same input now takes
  # about a twentieth of a second.
  #
  # Two bounds, and both earn their place: `bytes` stops a large payload, and
  # `lines` stops a host that streams blank lines forever — those cost no bytes
  # at all, so the byte bound alone would never trip.
  lines=0
  bytes=0
  line=""
  while IFS= read -r -t 1 line 2>/dev/null || [ -n "$line" ]; do
    parts[$lines]="$line"
    lines=$((lines + 1))
    bytes=$((bytes + ${#line} + 1))
    line=""
    # A hook payload is a few hundred bytes. Anything past this is a bug or a
    # probe, and Vigil's socket would refuse it anyway.
    [ "$bytes" -gt 65536 ] && break
    [ "$lines" -ge 4096 ] && break
  done
  if [ "$lines" -gt 0 ]; then
    oldifs=$IFS
    IFS=''
    INPUT="${parts[*]}"
    IFS=$oldifs
  fi
fi

# plutil parses JSON safely and is on every Mac; jq is not.
extract() { printf '%s' "$INPUT" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null || true; }

# Cut to a byte budget without leaving half a character behind.
#
# Cutting at a byte splits a multibyte character: BSD sed then refuses the whole
# string with "illegal byte sequence", and even under LC_ALL=C the half
# character makes the JSON body invalid UTF-8, so Vigil rejects the event
# entirely rather than merely losing the end of one field. `iconv -c` drops
# whatever did not survive the cut, so what we send is always valid UTF-8.
cap() { printf '%s' "$2" | head -c "$1" | /usr/bin/iconv -c -f UTF-8 -t UTF-8 2>/dev/null; }

# Cursor names it `conversation_id` and sends nothing called a session. Without
# this every Cursor event fell through to the `pid-NNNN` fallback, so one
# Cursor window's whole history of work collapsed into a single row keyed on a
# pid — and a row that is not keyed on the conversation cannot be told apart
# from the next conversation in the same window.
SESSION_ID=$(extract session_id)
[ -z "$SESSION_ID" ] && SESSION_ID=$(extract sessionId)
[ -z "$SESSION_ID" ] && SESSION_ID=$(extract conversation_id)
[ -z "$SESSION_ID" ] && SESSION_ID=$(extract conversationId)
CWD=$(extract cwd)
[ -z "$CWD" ] && CWD="$PWD"

# Bound everything that came out of the payload. The body has to stay under the
# 64KB the bridge accepts, or the event is refused outright — and losing the
# event is a great deal worse than losing the tail of an absurd cwd. Real
# session ids are UUIDs and real paths are under PATH_MAX, so nothing
# legitimate is cut here.
SESSION_ID=$(cap 256 "$SESSION_ID")
CWD=$(cap 1024 "$CWD")

# First line of the prompt, capped.
TITLE=$(cap 400 "$(extract prompt | head -n 1)")

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
