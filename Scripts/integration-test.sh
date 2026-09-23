#!/usr/bin/env bash
#
# Drives a real Vigil.app through its whole loop and checks the power
# assertion actually follows.
#
# The unit tests cover the decision logic and `make smoke` covers the panel
# building; this covers the part neither can: that a hook event arriving over
# the socket ends up changing macOS's power state.
#
#   make integration

set -uo pipefail
cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-Vigil}"
APP="dist/$APP_NAME.app"
SOCK="$HOME/Library/Application Support/$APP_NAME/bridge.sock"

pass=0
fail=0

check() {
  local what="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  ok    %s\n' "$what"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s (expected %s, got %s)\n' "$what" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

post() {
  curl -sS --unix-socket "$SOCK" -X POST http://localhost/event -m 3 \
    -d "$1" -o /dev/null -w '%{http_code}' 2>/dev/null
}

holding() {
  # Settle first: the model re-evaluates on a five-second tick.
  sleep 6
  # Capture first, then match. Piping into `grep -q` under `set -o pipefail`
  # reports failure on a *successful* match, because grep exits at the first
  # hit and pmset dies of SIGPIPE — so both outcomes would look like "no".
  # Match on our pid rather than the wording of the status line, which is
  # user-facing copy and has already broken this check once.
  local pid assertions
  pid="$(pgrep -x "$APP_NAME" | head -1)"
  [[ -n "$pid" ]] || { echo no; return; }
  assertions="$(pmset -g assertions 2>/dev/null)"
  case "$assertions" in
    *"pid $pid($APP_NAME)"*PreventUserIdleSystemSleep*) echo yes ;;
    *) echo no ;;
  esac
}

cleanup() {
  pkill -x "$APP_NAME" 2>/dev/null
  rm -f /tmp/vigil-oversized.json
}
trap cleanup EXIT

[[ -d "$APP" ]] || { echo "error: $APP not built — run make bundle" >&2; exit 1; }

# The wake-hold checks below assume Vigil is willing to hold. If a guardrail is
# active it will correctly refuse, and every one of them would read as a
# failure. Say so plainly rather than reporting a broken app.
battery="$(pmset -g batt | grep -oE '[0-9]+%' | tr -d '%' | head -1)"
on_mains="$(pmset -g batt | grep -c "AC Power")"
if [[ "$on_mains" -eq 0 && -n "$battery" && "$battery" -lt 25 ]]; then
  echo "skipped: battery is ${battery}% on battery power." >&2
  echo "Vigil's floor would correctly refuse to hold, so the wake checks" >&2
  echo "cannot distinguish a working app from a broken one. Plug in and rerun." >&2
  exit 0
fi

echo "==> launching"
pkill -x "$APP_NAME" 2>/dev/null
sleep 1
open "$APP"
sleep 3
pgrep -x "$APP_NAME" >/dev/null || { echo "error: app did not start" >&2; exit 1; }
[[ -S "$SOCK" ]] || { echo "error: socket not created at $SOCK" >&2; exit 1; }

echo "==> the loop"
check "health endpoint" "200" "$(curl -sS --unix-socket "$SOCK" -m 3 -o /dev/null -w '%{http_code}' http://localhost/health)"
check "idle at rest" "no" "$(holding)"

check "accepts a working event" "200" \
  "$(post '{"agent":"claude-code","session_id":"i1","state":"working","cwd":"/tmp/one"}')"
check "holds while an agent works" "yes" "$(holding)"

check "accepts a second agent" "200" \
  "$(post '{"agent":"codex","session_id":"i2","state":"working","cwd":"/tmp/two"}')"
check "still holding with two agents" "yes" "$(holding)"

check "accepts one going idle" "200" \
  "$(post '{"agent":"claude-code","session_id":"i1","state":"idle"}')"
check "still holding while one works" "yes" "$(holding)"

check "accepts the last going idle" "200" \
  "$(post '{"agent":"codex","session_id":"i2","state":"idle"}')"
check "releases when all are idle" "no" "$(holding)"

echo "==> hostile input"
check "rejects malformed JSON" "400" "$(post 'not json')"
check "rejects a missing session id" "400" "$(post '{"agent":"x","state":"working"}')"
check "rejects an unknown state" "400" "$(post '{"agent":"x","session_id":"s","state":"???"}')"

python3 -c "print('{\"agent\":\"x\",\"session_id\":\"s\",\"state\":\"working\",\"title\":\"' + 'A'*200000 + '\"}')" \
  > /tmp/vigil-oversized.json
check "refuses an oversized body" "413" \
  "$(curl -sS --unix-socket "$SOCK" -X POST http://localhost/event -m 5 \
     --data-binary @/tmp/vigil-oversized.json -o /dev/null -w '%{http_code}' 2>/dev/null)"

echo "==> still standing"
check "app survived all of that" "yes" "$(pgrep -x "$APP_NAME" >/dev/null && echo yes || echo no)"
check "and still works" "200" "$(post '{"agent":"claude-code","session_id":"i3","state":"idle"}')"

echo
if (( fail > 0 )); then
  echo "$fail failed, $pass passed"
  exit 1
fi
echo "all $pass checks passed"
