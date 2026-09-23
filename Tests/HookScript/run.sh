#!/usr/bin/env bash
#
# Regression tests for hooks/vigil-hook.sh.
#
#   make hooktest
#
# Two defects, both of which reached a release, and neither of which any Swift
# test can see: the script is bash, and what went wrong was how it read stdin.
#
#   1. The read was bounded on volume only — 64KB and 4096 lines — and the
#      1-second timeout is per *line*. A host emitting a line more often than
#      once a second reset it every time, so the loop ran until the line bound:
#      measured strictly linear at 10.99s for ten lines and 19.49s for twenty,
#      which puts the worst case a little over an hour, spent inside the user's
#      agent, exiting 0 with nothing posted. Now bounded by `SECONDS` too.
#
#   2. A read that stopped early left a JSON *prefix*, which plutil refuses
#      outright, so every field went missing at once and the event fell back to
#      a pid key. The matching idle event keys on the real session id, so
#      nothing could ever clear the `working` session and it held the Mac awake
#      until it went stale. The prefix is now scraped for a session id first.
#
# Why this is not in `make test`: the timing case has to watch a producer that
# keeps producing, so it takes seconds by construction. `make test` runs in
# under half a second and people run it constantly; a suite that sleeps does
# not belong in that loop. Same reasoning that separates `make smoke` and
# `make integration` from `make test`.
#
# Why this is not `make integration`: that one drives a real signed Vigil.app
# and reads real power assertions, so it cannot run while a Vigil instance is
# on the machine. Everything here is the hook script, a scratch directory and a
# socket that answers — no app, no build, nothing installed.
set -uo pipefail
cd "$(dirname "$0")/../.."

HOOK="$PWD/hooks/vigil-hook.sh"
SUPPORT="$PWD/Tests/HookScript/bridge.py"

# The hook must exit on its own well inside this. It is deliberately nowhere
# near the ~2s the fixed script takes: what is being asserted is the difference
# between bounded and unbounded, not a duration. A loaded machine can make the
# hook ten times slower and this still passes; only a hook that waits on its
# producer fails. The defect needed 4096 lines at the interval below — over
# twenty minutes — so there is no load under which the two are confusable.
TIMEOUT="${VIGIL_HOOK_TEST_TIMEOUT:-45}"
INTERVAL="${VIGIL_HOOK_TEST_INTERVAL:-0.3}"

pass=0
fail=0

check() {
  local what="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    printf '  ok    %s\n' "$what"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n          expected: %s\n          actual:   %s\n' \
      "$what" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

[ -x "$HOOK" ] || { echo "error: $HOOK is not executable" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

# A home of our own, and a short one.
#
# `sun_path` in a `sockaddr_un` is 104 bytes on Darwin, and the socket the hook
# opens is $HOME plus 46 more characters, so the home has to fit in 57. A
# macOS $TMPDIR is around 45 characters before anything is added to it, which
# does not, and the failure it produces is a silently truncated path and a
# `bind` that lands somewhere else — an hour of debugging for anyone who meets
# it. /tmp keeps it to 27. `mktemp -d` makes it 0700 and unpredictable, so
# /tmp being world-writable buys an attacker nothing here.
HOME_DIR="$(mktemp -d /tmp/vigil-hook-test.XXXXXX)" || exit 1
SOCKET="$HOME_DIR/Library/Application Support/Vigil/bridge.sock"
LOG="$HOME_DIR/posts.log"
READY="$HOME_DIR/ready"

if [ "${#SOCKET}" -ge 104 ]; then
  echo "error: socket path is ${#SOCKET} bytes, over the 104-byte AF_UNIX limit:" >&2
  echo "  $SOCKET" >&2
  rm -rf "$HOME_DIR"
  exit 1
fi

# Nothing below may reach the real home. The hook derives its socket, and only
# its socket, from $HOME, and every invocation here overrides it — but say so
# out loud rather than trusting it, because the cost of being wrong is posting
# test events into the developer's running Vigil.
case "$HOME_DIR" in
  /tmp/vigil-hook-test.*) ;;
  *) echo "error: refusing to run outside a scratch home: $HOME_DIR" >&2; exit 1 ;;
esac

listener=""
cleanup() {
  if [ -n "$listener" ]; then
    # Reaped here, or the shell reports "Terminated: 15" on the way out and
    # the last line of a passing run looks like a failure.
    kill "$listener" 2>/dev/null
    wait "$listener" 2>/dev/null
  fi
  rm -rf "$HOME_DIR"
}
trap cleanup EXIT

python3 "$SUPPORT" listen "$SOCKET" "$LOG" "$READY" &
listener=$!

waited=0
while [ ! -f "$READY" ] && [ "$waited" -lt 50 ]; do
  sleep 0.1
  waited=$((waited + 1))
done

# Checked, not assumed. The hook exits 0 the instant it finds no socket, so a
# test that raced the listener would pass against a hook that did nothing.
[ -f "$READY" ] || { echo "error: listener never came up" >&2; exit 1; }
[ -S "$SOCKET" ] || { echo "error: no socket at $SOCKET" >&2; exit 1; }

last_post() { tail -n 1 "$LOG" 2>/dev/null; }
field() { printf '%s' "$2" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
clear_log() { : > "$LOG"; }

echo "hook:   $HOOK"
echo "home:   $HOME_DIR"
echo "socket: ${#SOCKET} bytes"
echo "bash:   $(/bin/bash --version | head -1)"
echo

# ---------------------------------------------------------------------------
echo "an ordinary payload"
clear_log
HOME="$HOME_DIR" "$HOOK" claude-code UserPromptSubmit working \
  <<< '{"session_id":"hooktest-whole-0001","cwd":"/tmp/hooktest","prompt":"a whole payload"}'
body="$(last_post)"
check "posts one event"      "1"                      "$(grep -c . "$LOG")"
check "keeps the session id" "hooktest-whole-0001"    "$(field session_id "$body")"
check "keeps the cwd"        "/tmp/hooktest"          "$(field cwd "$body")"
check "keeps the title"      "a whole payload"        "$(field title "$body")"
check "keeps the state"      "working"                "$(field state "$body")"

# ---------------------------------------------------------------------------
# Defect 2, second half, on its own. stdin closes immediately, so this says
# nothing about timing — only that a payload plutil cannot parse is scraped
# for its session id rather than being given a pid key that the matching idle
# event will never use.
echo
echo "a payload that stops mid-object"
clear_log
printf '{"session_id":"hooktest-cut-0002","cwd":"/tmp/hooktest",' \
  | HOME="$HOME_DIR" "$HOOK" claude-code UserPromptSubmit working
body="$(last_post)"
check "posts one event"           "1"                    "$(grep -c . "$LOG")"
check "recovers the session id"   "hooktest-cut-0002"    "$(field session_id "$body")"
check "recovers the cwd"          "/tmp/hooktest"        "$(field cwd "$body")"

# ---------------------------------------------------------------------------
# Defect 2, first half. The producer emits a line every $INTERVAL and never
# closes stdin, so there is no EOF to reach and neither volume bound can be
# hit inside the timeout — the only way out is the clock.
echo
echo "a producer that never stops"
clear_log
result="$(python3 "$SUPPORT" run "$HOOK" "$HOME_DIR" "$INTERVAL" \
  hooktest-drip-0003 "$TIMEOUT" "$HOME_DIR/lines")"
rc=""; killed=""; elapsed=""; lines=""
for kv in $result; do
  case "$kv" in
    rc=*) rc="${kv#rc=}" ;;
    killed=*) killed="${kv#killed=}" ;;
    elapsed=*) elapsed="${kv#elapsed=}" ;;
    lines=*) lines="${kv#lines=}" ;;
  esac
done
if [ "$killed" = "0" ]; then
  echo "  (exited on its own after ${elapsed}s, having been fed $lines lines)"
else
  echo "  (still running at ${elapsed}s when it was killed, fed $lines lines)"
fi

check "returns without being killed" "0"   "$killed"
check "exits 0"                      "0"   "$rc"
# Stated as one check so that it reads correctly in a failing run too. A hook
# killed at the timeout has also been fed far fewer than 1000 lines, so "well
# short of the volume bounds" on its own would print `ok` next to the very
# failure it is there to explain. Those bounds need 4096 lines, or the ~1450
# it takes to pass 64KB at this line length; neither is reachable here.
check "the clock stopped it, not EOF and not a volume bound" "yes" \
  "$([ "$killed" = "0" ] && [ -n "$lines" ] && [ "$lines" -lt 1000 ] \
      && echo yes || echo "no (killed=$killed, $lines lines)")"

body="$(last_post)"
check "still posts its event"      "1"                     "$(grep -c . "$LOG")"
check "recovers the session id"    "hooktest-drip-0003"    "$(field session_id "$body")"

# ---------------------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
  echo "$pass checks passed"
  exit 0
fi
echo "$fail of $((pass + fail)) checks FAILED"
exit 1
