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
# /Library/PrivilegedHelperTools is Apple's designated location for privileged
# helpers: root:wheel, mode 1755, and every ancestor root-owned. /usr/local is
# not — Homebrew chowns it to the user on Intel Macs, and renaming a directory
# needs write permission only on its parent, so an attacker could swap the
# helper out from under a NOPASSWD rule.
readonly HELPER_DST=/Library/PrivilegedHelperTools/vigil-clamshell
readonly SUDOERS_FILE=/etc/sudoers.d/vigil-clamshell

if [[ $EUID -ne 0 ]]; then
  echo "error: run this with sudo" >&2
  exit 1
fi

# The user the rule is for — never root.
#
# SUDO_USER when run from a terminal. Vigil passes VIGIL_TARGET_USER instead,
# because an authorization prompt runs us as root directly with no sudo in the
# picture and therefore no SUDO_USER to read.
readonly TARGET_USER="${VIGIL_TARGET_USER:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" ]]; then
  echo "error: could not determine which user to grant this to." >&2
  echo "       Run with sudo, or set VIGIL_TARGET_USER." >&2
  exit 1
fi
if [[ "$TARGET_USER" == "root" ]]; then
  echo "error: refusing to write a rule for root" >&2
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

# A username is interpolated into a sudoers rule below. visudo validates syntax,
# not intent — a crafted name containing a newline would widen the grant and
# still parse. Refuse anything that is not a plain username.
if [[ ! "$TARGET_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "error: refusing to build a sudoers rule for unusual username '$TARGET_USER'" >&2
  exit 1
fi

# Every directory on the path to the helper must be root-owned and writable by
# nobody else. Checking the helper alone is not enough: renaming a directory
# needs write permission only on its parent, so a writable ancestor lets an
# attacker substitute the whole tree and inherit the NOPASSWD grant.
assert_ancestors_are_safe() {
  local path="$1" dir owner perms
  dir="$(dirname "$path")"
  while :; do
    if [[ -e "$dir" ]]; then
      owner="$(stat -f '%u' "$dir")"
      perms="$(stat -f '%OLp' "$dir")"
      if [[ "$owner" != "0" ]]; then
        echo "error: $dir is not owned by root (uid $owner)." >&2
        echo "       Anything able to write there could replace the helper and" >&2
        echo "       gain passwordless root. Refusing to install." >&2
        exit 1
      fi
      # Group- or other-writable, ignoring the sticky bit which is fine.
      if (( 8#$perms & 8#022 )); then
        echo "error: $dir is writable by group or others (mode $perms)." >&2
        echo "       Refusing to install." >&2
        exit 1
      fi
    fi
    [[ "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
}

install -d -o root -g wheel -m 0755 "$(dirname "$HELPER_DST")"
assert_ancestors_are_safe "$HELPER_DST"

# root-owned and not writable by anyone else. A NOPASSWD rule pointing at a
# user-writable file is a root shell, so this ownership is the whole safeguard.
install -o root -g wheel -m 0755 "$HELPER_SRC" "$HELPER_DST"

# Three literal argument vectors. No wildcards: `vigil-clamshell *` would let any
# argument through, and the helper is only safe because its input is fixed.
TMP_RULE="$(mktemp /tmp/vigil-sudoers.XXXXXX)"
trap 'rm -f "$TMP_RULE"' EXIT
cat > "$TMP_RULE" <<RULE
# Installed by Vigil (https://github.com/Rupareliaaniket22/vigil)
# Lets $TARGET_USER toggle lid-close sleep without a password prompt.
$TARGET_USER ALL=(root) NOPASSWD: $HELPER_DST on, $HELPER_DST off, $HELPER_DST sleep
RULE

chmod 0440 "$TMP_RULE"
chown root:wheel "$TMP_RULE"

# Validate before moving it into place. A malformed file in sudoers.d can lock
# the user out of sudo entirely, so this check is not optional.
if ! /usr/sbin/visudo -cqf "$TMP_RULE"; then
  echo "error: generated sudoers rule failed validation; nothing was installed" >&2
  exit 1
fi

mv "$TMP_RULE" "$SUDOERS_FILE"

echo "Installed."
echo "  helper:  $HELPER_DST"
echo "  rule:    $SUDOERS_FILE (for $TARGET_USER)"
echo
echo "Turn on 'Keep working with the lid closed' in Vigil's settings."
echo "To remove: sudo $0 --uninstall"
