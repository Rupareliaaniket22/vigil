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
#
# ## Why this launches the binary rather than the app
#
# Since `AppModel.start()` began calling `maintainHooks()`, launching Vigil is
# itself a write: it installs hooks into `~/.claude/settings.json`,
# `~/.codex/hooks.json`, `~/.gemini/settings.json` and `~/.cursor/hooks.json`,
# and records trust in `~/.codex/config.toml`, with nobody asked. A gate that
# every contributor is told to run must not do that to the machine it runs on.
#
# Two mechanisms keep it off the developer's files, and either one alone would
# be enough — which is the point of having both:
#
#   1. `CFFIXED_USER_HOME` points the app at a throwaway home, so every path it
#      derives from `$HOME` — the four settings files, `config.toml`, the hook
#      script, the socket — lands inside a temporary directory. This is why the
#      app is started as `Contents/MacOS/Vigil` and not with `open`: `open`
#      hands the request to LaunchServices, which launches the app from its own
#      environment and not from this shell's, so an exported variable never
#      reaches it.
#
#   2. `-managesAgentHooks '<false/>'` turns automatic hook management off for
#      this one launch. That is not a private switch: `managesAgentHooks` is
#      the same preference the settings window writes, and the argument is read
#      through Foundation's `NSArgumentDomain`, which shadows the stored value
#      for the lifetime of the process and writes nothing. The odd spelling is
#      required — the argument domain stores a bare `NO` or `0` as a *string*,
#      and `HookManagement.manages` reads a `Bool`; `<false/>` is parsed as a
#      property list and arrives as one. The settings window binds to the same
#      key, so an app launched this way also *shows* management as off, which
#      is what makes it a runtime mode rather than a back door.
#
# The second mechanism is what protects state the first one cannot reach.
# `CFFIXED_USER_HOME` does not isolate `UserDefaults`: CFPreferences resolves
# the real home through `cfprefsd`, so `managesAgentHooks`,
# `agentsVigilHasSetUp` and `agentsVigilHasTrusted` are read from and written
# to the developer's real `io.github.rupareliaaniket22.vigil` domain whatever
# `$HOME` says.
# `agentsVigilHasSetUp` is the record that makes a removal stick, so a run that
# wrote it would quietly take a real agent out of reach of automatic setup on a
# machine where nothing visible had changed.
#
# Neither mechanism is trusted silently. The checks under "left the developer's
# machine alone" fail the run if any of the five real files changed, if any of
# the three preferences changed, or if anything was written into the fake
# agents' directories — the last of which is what an argument domain that
# stopped working would look like.

set -uo pipefail
cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-Vigil}"
APP="dist/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"

# `sockaddr_un.sun_path` holds 104 bytes, and the socket is the home plus
# `/Library/Application Support/Vigil/bridge.sock` — 46 characters. A home
# longer than 57 would be bound at a silently truncated path by anything that
# did not check; the bridge refuses it loudly instead, which would read here as
# a bridge that never came up. `/tmp/vigil-it.XXXXXX` is 20.
FAKE_HOME="$(mktemp -d /tmp/vigil-it.XXXXXX)"
SOCK="$FAKE_HOME/Library/Application Support/$APP_NAME/bridge.sock"

# The four agents Vigil knows how to wire up. Created empty because
# `refreshInstalledAgents` only offers an integration whose settings directory
# exists — without them the app would find no agents at all, and "wrote nothing
# into the fake agents' directories" would pass for the wrong reason.
FAKE_AGENT_DIRS=(.claude .codex .gemini .cursor)

# The developer's own files, in the order the report prints them. Every path an
# install or a trust write can reach.
REAL_CONFIGS=(
  "$HOME/.claude/settings.json"
  "$HOME/.codex/hooks.json"
  "$HOME/.codex/config.toml"
  "$HOME/.gemini/settings.json"
  "$HOME/.cursor/hooks.json"
)
# The preferences that decide whether a removal sticks and what the settings
# rows say Vigil has done. `UserDefaults`, so a fake home cannot reach them.
REAL_DEFAULTS=(managesAgentHooks agentsVigilHasSetUp agentsVigilHasTrusted)
DEFAULTS_DOMAIN="${BUNDLE_ID:-io.github.rupareliaaniket22.vigil}"

APP_PID=""

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

# A fingerprint of the files this run must not touch.
#
# Missing is a state like any other and has to be recorded as one: a file that
# did not exist before and does now is exactly the failure being watched for,
# and an `md5` of nothing would report it as unchanged.
real_config_state() {
  local path
  for path in "${REAL_CONFIGS[@]}"; do
    if [[ -f "$path" ]]; then
      printf '%s %s\n' "$path" "$(md5 -q "$path")"
    else
      printf '%s absent\n' "$path"
    fi
  done
}

# The same, for the preferences a fake home cannot isolate.
real_defaults_state() {
  local key
  for key in "${REAL_DEFAULTS[@]}"; do
    printf '%s %s\n' "$key" \
      "$(defaults read "$DEFAULTS_DOMAIN" "$key" 2>/dev/null | tr '\n' ' ' || echo absent)"
  done
}

holding() {
  # Settle first: the model re-evaluates on a five-second tick.
  sleep 6
  # Capture first, then match. Piping into `grep -q` under `set -o pipefail`
  # reports failure on a *successful* match, because grep exits at the first
  # hit and pmset dies of SIGPIPE — so both outcomes would look like "no".
  # Match on the pid we launched rather than the wording of the status line,
  # which is user-facing copy and has already broken this check once.
  [[ -n "$APP_PID" ]] || { echo no; return; }
  kill -0 "$APP_PID" 2>/dev/null || { echo no; return; }
  # Our pid's own line, not the whole report: pmset lists one line per
  # assertion under "Listed by owning process", and matching the process and
  # the assertion type anywhere in the output would let somebody else's
  # PreventUserIdleSystemSleep answer for ours.
  local line
  line="$(pmset -g assertions 2>/dev/null | grep -F "pid $APP_PID($APP_NAME)" | head -1 || true)"
  case "$line" in
    *PreventUserIdleSystemSleep*) echo yes ;;
    *) echo no ;;
  esac
}

cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
  rm -f /tmp/vigil-oversized.json
  # Guarded rather than trusted: an `rm -rf` on an empty variable is an `rm -rf`
  # on the working directory.
  case "$FAKE_HOME" in
    /tmp/vigil-it.??????) rm -rf "$FAKE_HOME" ;;
  esac
}
trap cleanup EXIT

[[ -x "$BIN" ]] || { echo "error: $BIN not built — run make bundle" >&2; exit 1; }

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

configs_before="$(real_config_state)"
defaults_before="$(real_defaults_state)"

echo "==> launching (home: $FAKE_HOME)"
# Any instance already running would put a second icon in the menu bar and a
# second Vigil in the assertion ledger. It is not a correctness problem — this
# run has its own home, its own socket and its own pid — but it is confusing to
# read, and `make bundle` has already replaced the bundle underneath it.
pkill -x "$APP_NAME" 2>/dev/null
sleep 1
for dir in "${FAKE_AGENT_DIRS[@]}"; do mkdir -p "$FAKE_HOME/$dir"; done

CFFIXED_USER_HOME="$FAKE_HOME" "$BIN" -managesAgentHooks '<false/>' \
  >"$FAKE_HOME/app.log" 2>&1 &
APP_PID=$!

# Wait for the socket rather than sleeping a guessed number of seconds. A
# socket in the fake home is also the proof that `CFFIXED_USER_HOME` reached
# the app at all: if it had not, this would time out while the app sat there
# listening in the developer's real home.
for _ in $(seq 1 20); do
  [[ -S "$SOCK" ]] && break
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 0.5
done
kill -0 "$APP_PID" 2>/dev/null || {
  echo "error: app did not stay up — log follows" >&2
  cat "$FAKE_HOME/app.log" >&2
  exit 1
}
[[ -S "$SOCK" ]] || {
  echo "error: socket not created at $SOCK" >&2
  echo "the app is running, so CFFIXED_USER_HOME did not reach it" >&2
  exit 1
}

echo "==> the loop"
check "health endpoint" "200" "$(curl -sS --unix-socket "$SOCK" -m 3 -o /dev/null -w '%{http_code}' http://localhost/health)"
# No "a real agent is working on this machine" escape hatch any more, and none
# is needed: hooks post to the socket under the *agent's* home, which is the
# developer's, and this app is listening under a temporary one. Nothing but
# this script can reach it.
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
check "app survived all of that" "yes" \
  "$(kill -0 "$APP_PID" 2>/dev/null && echo yes || echo no)"
check "and still works" "200" "$(post '{"agent":"claude-code","session_id":"i3","state":"idle"}')"

echo "==> left the developer's machine alone"
# After the app has stopped, so anything it was going to write has been
# written. Launching is the moment hooks get installed, so this is the check
# that says the gate is safe to run — not a courtesy at the end of one.
kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null
check "the four agent settings files and config.toml unchanged" "same" \
  "$([[ "$(real_config_state)" == "$configs_before" ]] && echo same || echo CHANGED)"
check "Vigil's own record of what it has set up unchanged" "same" \
  "$([[ "$(real_defaults_state)" == "$defaults_before" ]] && echo same || echo CHANGED)"
# What an argument domain that stopped shadowing `managesAgentHooks` would look
# like: the app finds four agent directories in its fake home, decides none of
# them is set up, and writes a settings file into each.
check "wrote nothing into the fake agents' directories" "0" \
  "$(find "$FAKE_HOME/.claude" "$FAKE_HOME/.codex" "$FAKE_HOME/.gemini" \
     "$FAKE_HOME/.cursor" -type f 2>/dev/null | wc -l | tr -d ' ')"

echo
if (( fail > 0 )); then
  echo "$fail failed, $pass passed"
  # Worth having on screen when something failed, and noise when nothing did.
  echo "--- app log ---"
  cat "$FAKE_HOME/app.log"
  exit 1
fi
echo "all $pass checks passed"
