#!/usr/bin/env bash
#
# Regression tests for hooks/vigil-hook.sh.
#
#   make hooktest
#
# Three defects, all of which reached a release, and none of which any Swift
# test can see: the script is bash, and what went wrong was how it read stdin
# and what it made of what it read.
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
#   3. Cursor's payload carries no `cwd` at all — the working directory is in
#      `workspace_roots`, an array — so `extract cwd` came back empty every
#      time and every Cursor row was labelled with whatever directory the hook
#      process happened to inherit from Cursor. The same wrong path for every
#      window, and never the user's project. The first workspace root is now
#      the answer, and a window with no folder open reports no path at all
#      rather than that one.
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
# `field` cannot tell an empty value from an absent one — both come back as the
# empty string — and one check below is precisely that the cwd is empty rather
# than invented. That one asks the body itself.
contains() { case "$2" in *"$1"*) echo yes ;; *) echo "no: $2" ;; esac; }

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
# Defect 3. Cursor's payload is a shape nothing else in this file has: no `cwd`
# anywhere in it, the session under a different name, and the working directory
# only in `workspace_roots`. The fields below are the ones Cursor really sends —
# it adds `hook_event_name`, `cursor_version`, `workspace_roots`, `user_email`
# and `transcript_path` to every hook payload it builds, and a `cwd` to none of
# them.
#
# The roots are deliberately nowhere near this script's own directory, which is
# the repo root: that inherited path is what the defect posted, so a check that
# expected it would pass against the defect.
echo
echo "a Cursor payload"
clear_log
stdout="$(HOME="$HOME_DIR" "$HOOK" cursor afterFileEdit working <<< '{"conversation_id":"hooktest-cursor-0004","generation_id":"hooktest-gen-0004","hook_event_name":"afterFileEdit","cursor_version":"3.21.18","workspace_roots":["/tmp/hooktest-cursor"],"user_email":"nobody@example.com","transcript_path":"/tmp/hooktest-cursor/.cursor/transcript.json","file_path":"/tmp/hooktest-cursor/Sources/main.swift"}')"
body="$(last_post)"
check "posts one event"                   "1"                     "$(grep -c . "$LOG")"
check "keys on the conversation id"       "hooktest-cursor-0004"  "$(field session_id "$body")"
check "labels it with the workspace root" "/tmp/hooktest-cursor"  "$(field cwd "$body")"
check "not the directory it inherited"    "yes" \
  "$([ "$(field cwd "$body")" != "$PWD" ] && echo yes || echo "no (labelled $PWD)")"
# Cursor reads stdout for a verdict only on the hooks Vigil does not register
# for. Saying anything on one it does register for would be voting on it.
check "says nothing on a hook Vigil registers for" "" "$stdout"

# ---------------------------------------------------------------------------
# A multi-root workspace. One row, one path: the first root, which is the
# folder Cursor itself lists first.
echo
echo "a Cursor window with two folders open"
clear_log
HOME="$HOME_DIR" "$HOOK" cursor afterShellExecution working \
  <<< '{"conversation_id":"hooktest-cursor-0005","hook_event_name":"afterShellExecution","cursor_version":"3.21.18","workspace_roots":["/tmp/hooktest-cursor-first","/tmp/hooktest-cursor-second"],"user_email":"nobody@example.com","command":"swift build","exit_code":0}'
body="$(last_post)"
check "takes the first root" "/tmp/hooktest-cursor-first" "$(field cwd "$body")"

# ---------------------------------------------------------------------------
# No folder open, so there is no project to name. The event still has to be
# posted — the session is real, and something has to clear it — but the path
# has to be empty rather than the hook's own directory, which belongs to
# Cursor. The panel draws a session's path only when it is non-empty, so such
# a row is simply the agent's name.
echo
echo "a Cursor window with no folder open"
clear_log
HOME="$HOME_DIR" "$HOOK" cursor afterAgentThought working \
  <<< '{"conversation_id":"hooktest-cursor-0006","hook_event_name":"afterAgentThought","cursor_version":"3.21.18","workspace_roots":[],"user_email":"nobody@example.com"}'
body="$(last_post)"
check "posts one event"             "1"                     "$(grep -c . "$LOG")"
check "keys on the conversation id" "hooktest-cursor-0006"  "$(field session_id "$body")"
check "reports no path at all"      "yes"                   "$(contains '"cwd":""' "$body")"

# ---------------------------------------------------------------------------
# Defects 2 and 3 together: a Cursor payload that stopped mid-object. plutil
# refuses a prefix, so both the id and the root have to come out of the scrape
# — and an array is a shape the id scrape cannot read.
echo
echo "a Cursor payload that stops mid-object"
clear_log
printf '{"conversation_id":"hooktest-cursor-0007","hook_event_name":"afterFileEdit","workspace_roots":["/tmp/hooktest-cursor-cut","/tmp/hooktest-cursor-other",' \
  | HOME="$HOME_DIR" "$HOOK" cursor afterFileEdit working
body="$(last_post)"
check "posts one event"              "1"                         "$(grep -c . "$LOG")"
check "recovers the conversation id" "hooktest-cursor-0007"      "$(field session_id "$body")"
check "recovers the first root"      "/tmp/hooktest-cursor-cut"  "$(field cwd "$body")"

# ---------------------------------------------------------------------------
# A host that sends both. `cwd` is the more specific answer and wins; the roots
# are the whole window, and only stand in when there is nothing better.
echo
echo "a payload carrying both a cwd and workspace roots"
clear_log
HOME="$HOME_DIR" "$HOOK" cursor afterFileEdit working \
  <<< '{"conversation_id":"hooktest-cursor-0008","cwd":"/tmp/hooktest-cwd","workspace_roots":["/tmp/hooktest-roots"]}'
body="$(last_post)"
check "prefers the cwd" "/tmp/hooktest-cwd" "$(field cwd "$body")"

# ---------------------------------------------------------------------------
# Not about payloads, and here because the sections above are the only other
# place Cursor's stdout is looked at. An entry written by an older Vigil is
# still sitting in somebody's hooks.json, blocking every command they run, and
# these four names are answered so that it stops the moment the script is
# updated. The list must not grow: answering a hook Vigil never registered for
# would be voting on it.
echo
echo "a Cursor permission hook left behind by an older install"
clear_log
check "allows the permission hooks" '{"permission":"allow"}' \
  "$(HOME="$HOME_DIR" "$HOOK" cursor beforeShellExecution working < /dev/null)"
check "answers beforeSubmitPrompt in its own currency" '{"continue":true}' \
  "$(HOME="$HOME_DIR" "$HOOK" cursor beforeSubmitPrompt working < /dev/null)"

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
