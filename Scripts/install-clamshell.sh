#!/usr/bin/env bash
#
# Installs Vigil's clamshell helper. Run with sudo:
#
#   sudo ./Scripts/install-clamshell.sh
#   sudo ./Scripts/install-clamshell.sh --uninstall
#
# What this grants: your user may run one specific program, with one of two
# literal arguments, as root without a password. That program can only call
# `pmset -a disablesleep`. It cannot run anything else.
#
# Why it needs root at all: keeping a Mac awake with the lid shut means clearing
# SleepDisabled on IOPMrootDomain, which is privileged. The unprivileged wake
# lock Vigil uses the rest of the time needs none of this.

set -euo pipefail

readonly HELPER_SRC="$(cd "$(dirname "$0")" && pwd)/clamshell-helper.sh"
readonly HELPER_DST=/usr/local/libexec/vigil-clamshell
readonly SUDOERS_FILE=/etc/sudoers.d/vigil-clamshell

if [[ $EUID -ne 0 ]]; then
  echo "error: run this with sudo" >&2
  exit 1
fi

# The invoking user, not root.
readonly TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" ]]; then
  echo "error: could not determine the invoking user; run via sudo, not as root directly" >&2
  exit 1
fi

uninstall() {
  rm -f "$SUDOERS_FILE" "$HELPER_DST"
  # Leave sleep in its normal state rather than however Vigil left it.
  /usr/bin/pmset -a disablesleep 0 || true
  echo "Removed. Lid-close sleeps normally again."
}

if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall
  exit 0
fi

[[ -f "$HELPER_SRC" ]] || { echo "error: $HELPER_SRC not found" >&2; exit 1; }

install -d -o root -g wheel -m 0755 /usr/local/libexec
# root-owned and not writable by anyone else. A NOPASSWD rule pointing at a
# user-writable file is a root shell, so this ownership is the whole safeguard.
install -o root -g wheel -m 0755 "$HELPER_SRC" "$HELPER_DST"

# Three literal argument vectors. No wildcards: `vigil-clamshell *` would let any
# argument through, and the helper is only safe because its input is fixed.
cat > "$SUDOERS_FILE.tmp" <<RULE
# Installed by Vigil (https://github.com/Rupareliaaniket22/vigil)
# Lets $TARGET_USER toggle lid-close sleep without a password prompt.
$TARGET_USER ALL=(root) NOPASSWD: $HELPER_DST on, $HELPER_DST off, $HELPER_DST sleep
RULE

chmod 0440 "$SUDOERS_FILE.tmp"
chown root:wheel "$SUDOERS_FILE.tmp"

# Validate before moving it into place. A malformed file in sudoers.d can lock
# the user out of sudo entirely, so this check is not optional.
if ! /usr/sbin/visudo -cqf "$SUDOERS_FILE.tmp"; then
  rm -f "$SUDOERS_FILE.tmp"
  echo "error: generated sudoers rule failed validation; nothing was installed" >&2
  exit 1
fi

mv "$SUDOERS_FILE.tmp" "$SUDOERS_FILE"

echo "Installed."
echo "  helper:  $HELPER_DST"
echo "  rule:    $SUDOERS_FILE (for $TARGET_USER)"
echo
echo "Turn on 'Keep working with the lid closed' in Vigil's settings."
echo "To remove: sudo $0 --uninstall"
