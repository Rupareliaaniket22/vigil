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
# Exits 0 on every path, and returns in bounded time on every path. Reading the
# host's stdin is the only place this script can wait at all, and that read is
# bounded three ways — bytes, lines and wall clock. This runs inside someone's
# coding agent, on their critical path: if it hangs or fails loudly, they blame
# the agent.
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
  # Three bounds, and each one stops a runaway the other two cannot see.
  # `bytes` stops a large payload. `lines` stops a host that streams blank
  # lines forever — those cost no bytes at all, so the byte bound alone would
  # never trip. `SECONDS` stops the shape neither of them bounds: `-t 1` is a
  # timeout *per line*, so a host emitting a line more often than once a second
  # resets it every time and the loop never ends on its own. Measured on the
  # volume bounds alone, a line every 0.9s ran for 10.99s at ten lines and
  # 19.49s at twenty — strictly linear, so the 4096-line bound is the real
  # limit at a little over an hour, spent inside the user's agent, exiting 0
  # with nothing posted and nothing anywhere to say why.
  #
  # `SECONDS` is the whole of bash 3.2's clock: no `EPOCHSECONDS`, no
  # `EPOCHREALTIME`, and shelling out to `date` on every line would cost more
  # than the loop. It is enough here — it is assignable, so resetting it to 0
  # makes it count this loop rather than the life of the shell, and a bound
  # measured in whole seconds wants no finer resolution than that.
  #
  # Two seconds, because the normal case never sees it: a few hundred bytes
  # arriving at once reaches EOF on the first pass, which is why the ordinary
  # invocation below still takes about a tenth of a second. Anything still
  # arriving two seconds in is a host that is streaming rather than handing
  # over a payload, and the event it is holding up is already late.
  lines=0
  bytes=0
  line=""
  SECONDS=0
  while IFS= read -r -t 1 line 2>/dev/null || [ -n "$line" ]; do
    parts[$lines]="$line"
    lines=$((lines + 1))
    bytes=$((bytes + ${#line} + 1))
    line=""
    # A hook payload is a few hundred bytes. Anything past this is a bug or a
    # probe, and Vigil's socket would refuse it anyway.
    #
    # Checked after the line is stored rather than before, deliberately:
    # compact JSON is a single line, so that one line *is* the whole payload.
    # Refusing to store it for being over budget would throw away something
    # that parses perfectly, to save memory `read` has already spent.
    [ "$bytes" -gt 65536 ] && break
    [ "$lines" -ge 4096 ] && break
    [ "$SECONDS" -ge 2 ] && break
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

# The same question, asked of a payload that is no longer JSON.
#
# What a read that stops early leaves behind is a *prefix* of an object, and
# plutil refuses a prefix outright — so every field goes missing at once and
# the event falls back to the pid key. That is the one key the matching idle
# event will never use: its payload is small, it parses, and it keys on the
# real session id. The `working` session left under the pid key therefore has
# nothing that can ever clear it, and it holds the Mac awake until it goes
# stale. Scraping the prefix costs one sed and usually recovers the real id,
# because hosts write it near the front of the object.
#
# Only reached for a payload that is not JSON at all. One that parsed has
# already given its real answer, and a `"session_id"` nested inside some other
# object is not something this should go looking for.
#
# `tr` first, so the match is the *first* occurrence rather than the last: the
# lines were joined with nothing between them, BSD sed has no non-greedy match,
# and a leading `.*` would run to the end of what is now one enormous line. A
# value containing `{` or `,` is split and simply fails to match, which is the
# safe direction — a partial id would key a session nothing could clear either.
scrape() {
  printf '%s' "$INPUT" | LC_ALL=C tr '{,' '\n\n' \
    | LC_ALL=C sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | head -n 1
}

# Whether what arrived is JSON at all — the difference between "this payload
# has no session id in it" and "it has one and the read stopped short of it".
#
# Every way the read can end early lands here, not just the bounds above: a
# host that writes half its payload and then holds the pipe open ends the loop
# on the per-line timeout instead, with exactly the same prefix to show for it.
#
# `-lint` is the obvious call and the wrong one: given `-` it reads stdin as a
# property list first and rejects every JSON document there is with "Unexpected
# character {". Converting the payload to the format it is already in is the
# check that answers the question. Only the exit status matters, so the
# conversion itself goes to /dev/null.
parses() { printf '%s' "$INPUT" | /usr/bin/plutil -convert json -o /dev/null - 2>/dev/null; }

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

# Same four names, asked of a payload that stopped mid-object. Nothing above
# answered and there is something to answer from, so the one extra parse this
# costs is paid only by a payload that already went wrong.
if [ -z "$SESSION_ID" ] && [ -n "$INPUT" ] && ! parses; then
  SESSION_ID=$(scrape session_id)
  [ -z "$SESSION_ID" ] && SESSION_ID=$(scrape sessionId)
  [ -z "$SESSION_ID" ] && SESSION_ID=$(scrape conversation_id)
  [ -z "$SESSION_ID" ] && SESSION_ID=$(scrape conversationId)
  [ -z "$CWD" ] && CWD=$(scrape cwd)
fi

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
