#!/bin/bash
# Vigil hook for Claude Code.
#
# Claude Code runs this on lifecycle events and pipes the event JSON on stdin.
# We collapse that to a state and post it to Vigil's local socket. Exits 0
# unconditionally — a keep-awake utility must never break the agent it watches.
set -u
EVENT="${1:-Unknown}"
SOCKET="$HOME/Library/Application Support/Vigil/bridge.sock"

[ -S "$SOCKET" ] || exit 0

INPUT=$(cat 2>/dev/null || true)
extract() { printf '%s' "$INPUT" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null || true; }

SESSION_ID=$(extract session_id)
CWD=$(extract cwd)
TITLE=$(extract prompt | head -c 200)

case "$EVENT" in
  UserPromptSubmit|PreToolUse|PostToolUse|SubagentStart|SubagentStop) STATE="working" ;;
  Notification)                                                      STATE="waiting" ;;
  *)                                                                 STATE="idle" ;;
esac

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }

PAYLOAD=$(printf '{"agent":"claude-code","session_id":"%s","state":"%s","event":"%s","pid":%d,"cwd":"%s","title":"%s"}' \
  "$(json_escape "${SESSION_ID:-pid-$PPID}")" "$STATE" "$EVENT" "${PPID:-0}" \
  "$(json_escape "$CWD")" "$(json_escape "$TITLE")")

/usr/bin/curl -sS --unix-socket "$SOCKET" \
  --connect-timeout 0.25 --max-time 1 -o /dev/null \
  -X POST "http://localhost/event" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" >/dev/null 2>&1

exit 0
