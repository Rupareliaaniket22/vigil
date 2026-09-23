#!/bin/bash
#
# Vigil's clamshell helper. Runs as root via a scoped sudoers rule.
#
# This is the only part of Vigil that runs with privilege, so it does exactly
# one thing and validates its input strictly. It takes precisely one argument —
# "on", "off" or "sleep" — and rejects everything else. There is no path through
# it that runs a command built from its input.
#
# Installed by Scripts/install-clamshell.sh to
# /Library/PrivilegedHelperTools/vigil-clamshell, owned by root, mode 0755.
# Not /usr/local: Homebrew chowns that to the user on Intel Macs, and a
# NOPASSWD rule pointing into a user-writable tree is a root shell. The
# installer explains the ancestor check that enforces this.

set -euo pipefail
IFS=$'\n\t'

readonly PMSET=/usr/bin/pmset

# Exactly one argument. No flags, no pass-through, no shifting.
if [[ $# -ne 1 ]]; then
  echo "usage: vigil-clamshell on|off|sleep" >&2
  exit 64
fi

# `sleep` exists because clearing the flag is not enough on its own. macOS only
# re-evaluates clamshell sleep on a lid open/close event, so with the lid
# already shut, restoring the flag leaves the Mac awake indefinitely — it is
# merely *permitted* to sleep, and nothing asks it to. A battery cutoff that
# only clears the flag drains the machine to empty anyway.
case "$1" in
  on)    want=1; then_sleep=0 ;;
  off)   want=0; then_sleep=0 ;;
  sleep) want=0; then_sleep=1 ;;
  *)
    echo "vigil-clamshell: expected 'on', 'off' or 'sleep', got '$1'" >&2
    exit 64
    ;;
esac

# pmset prints "must be run as root" and still exits 0, so its exit status
# cannot be trusted. Apply the change, then read the value back and confirm.
"$PMSET" -a disablesleep "$want" >/dev/null 2>&1 || true

got="$("$PMSET" -g 2>/dev/null | /usr/bin/awk '/SleepDisabled/ {print $2; exit}')"

if [[ "$got" != "$want" ]]; then
  echo "vigil-clamshell: SleepDisabled is '${got:-unknown}', expected '$want'" >&2
  exit 1
fi

if [[ "$then_sleep" == "1" ]]; then
  exec "$PMSET" sleepnow
fi

exit 0
