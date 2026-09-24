#!/usr/bin/env bash
#
# Remove everything Vigil put on this Mac.
#
#   Scripts/uninstall.sh                 # from a checkout
#   /Applications/Vigil.app/Contents/Resources/uninstall.sh
#
#   --dry-run          say what would go, change nothing
#   --include-backups  also delete the <file>.vigil-backup copies
#   --yes              don't ask
#
# Why this exists as a script rather than a list in the README: Vigil writes to
# nine places, three of them owned by root, and one of them is a NOPASSWD
# sudoers rule. A README paste that people get half-way through leaves the
# root-owned half of that behind, attached to an app that no longer exists.
#
# Run it as yourself, not with sudo. It refuses to run as root so that $HOME is
# always the home being cleaned, and calls sudo itself for the two root-owned
# paths — which means you see the prompt and know which step asked for it.

set -uo pipefail

DRY=0
YES=0
BACKUPS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --include-backups) BACKUPS=1 ;;
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "error: run this as yourself, not with sudo." >&2
  echo "       Under sudo, \$HOME is root's and this would clean the wrong home." >&2
  echo "       It asks for your password itself when it reaches the root-owned parts." >&2
  exit 1
fi

# Both identifiers, on purpose. Vigil was `dev.vigil.app` before its first
# release and is `io.github.rupareliaaniket22.vigil` after it; nothing was ever
# published under the old one, but a machine that built Vigil from source
# during that window has preferences and a login item filed under it. Removing
# only the current one would leave those behind for exactly the people who
# helped test it.
BUNDLE_IDS=(io.github.rupareliaaniket22.vigil dev.vigil.app)

HOOK_SCRIPT="$HOME/.vigil/hooks/vigil-hook.sh"
VIGIL_DIR="$HOME/.vigil"
SUPPORT_DIR="$HOME/Library/Application Support/Vigil"
HELPER=/Library/PrivilegedHelperTools/vigil-clamshell
SUDOERS=/etc/sudoers.d/vigil-clamshell

# The four agents Vigil wires up, and the file it writes a trust record into.
AGENT_CONFIGS=(
  "$HOME/.claude/settings.json"
  "$HOME/.codex/hooks.json"
  "$HOME/.gemini/settings.json"
  "$HOME/.cursor/hooks.json"
)
CODEX_CONFIG="$HOME/.codex/config.toml"

removed=()
kept=()

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# Every removal goes through here so --dry-run is one branch rather than a
# promise each caller has to remember to keep.
gone() {
  local what="$1" path="$2"
  if (( DRY )); then
    note "would remove   $path"
  elif rm -rf "$path"; then
    note "removed        $path"
    removed+=("$what: $path")
  else
    note "COULD NOT REMOVE $path"
  fi
}

say "Vigil — uninstall"
say

# ---------------------------------------------------------------------------
# 1. Hook entries in other programs' config files.
#
# This script does not edit them, and that is a decision rather than an
# omission. Removing a hook entry means rewriting someone's JSON or TOML
# around it without disturbing anything else in the file — which is precisely
# what `HookConfiguration` does in Swift, with tests, and what `sed` cannot do
# safely. A botched edit here costs the user their agent, not their wake lock.
#
# So: detect, report, and let that decide whether the shared script may go.
# ---------------------------------------------------------------------------
entries_found=0
say "Agent hook entries"
for cfg in "${AGENT_CONFIGS[@]}"; do
  if [[ -f "$cfg" ]] && grep -q '\.vigil/hooks/vigil-hook\.sh' "$cfg" 2>/dev/null; then
    n=$(grep -c '\.vigil/hooks/vigil-hook\.sh' "$cfg" 2>/dev/null || echo 0)
    note "STILL PRESENT  $cfg  ($n entries)"
    entries_found=1
  elif [[ -f "$cfg" ]]; then
    note "clean          $cfg"
  fi
done
if [[ -f "$CODEX_CONFIG" ]] && grep -q '^\[hooks\.state\.' "$CODEX_CONFIG" 2>/dev/null; then
  note "trust records  $CODEX_CONFIG — check [hooks.state] sections"
fi
say

if (( entries_found )); then
  cat <<'WARN'
  Those entries still name Vigil's hook script. Take them out from inside the
  app first: open Settings from the panel, then Vigil -> Remove Vigil from
  This Mac... in the menu bar. That clears every agent at once and withdraws
  the Codex trust records. (Vigil's menu only appears in the menu bar while
  its Settings window is open. Settings -> each agent -> Remove does the same
  thing one at a time.) Only the app knows how to edit those files safely.

  If the app is already gone, edit each file by hand and delete the entries
  whose command contains `.vigil/hooks/vigil-hook.sh`. A `<file>.vigil-backup`
  copy sits beside each one, from before Vigil's first edit.

  Until they are gone this script LEAVES the hook script in place, because an
  entry pointing at a deleted script is worse than one pointing at a live one:
  the script exits 0 in a few milliseconds and does nothing when Vigil is not
  running, while a missing file makes every agent report a failed hook on
  every event.
WARN
  say
fi

if (( ! YES && ! DRY )); then
  printf 'Remove the rest? [y/N] '
  read -r reply
  [[ "$reply" == [yY]* ]] || { say "Nothing was changed."; exit 0; }
  say
fi

# ---------------------------------------------------------------------------
# 2. Vigil's own files.
# ---------------------------------------------------------------------------
say "Vigil's own files"
if [[ -e "$HOOK_SCRIPT" ]]; then
  if (( entries_found )); then
    note "kept           $HOOK_SCRIPT (still referenced — see above)"
    kept+=("$HOOK_SCRIPT")
  else
    gone "hook script" "$HOOK_SCRIPT"
    # rmdir, not rm -rf: if anything else is in ~/.vigil it is not ours.
    if (( ! DRY )); then
      rmdir "$VIGIL_DIR/hooks" 2>/dev/null && rmdir "$VIGIL_DIR" 2>/dev/null \
        && note "removed        $VIGIL_DIR"
    fi
  fi
fi

# The socket lives here. Vigil does not unlink it on exit, so it outlives the
# app; a stale socket costs every hook invocation a connect that cannot succeed.
if [[ -e "$SUPPORT_DIR" ]]; then
  gone "support dir" "$SUPPORT_DIR"
fi
say

# ---------------------------------------------------------------------------
# 3. Preferences and the login item.
# ---------------------------------------------------------------------------
say "Preferences"
for id in "${BUNDLE_IDS[@]}"; do
  # `defaults read` to test, because `defaults delete` on a domain that is not
  # there prints an error and returns non-zero.
  if defaults read "$id" >/dev/null 2>&1; then
    if (( DRY )); then
      note "would remove  defaults domain $id"
    else
      defaults delete "$id" >/dev/null 2>&1 && note "removed        defaults domain $id"
    fi
  fi
  plist="$HOME/Library/Preferences/$id.plist"
  [[ -e "$plist" ]] && gone "prefs plist" "$plist"
done
say

cat <<'LOGIN'
Login item
  If Launch at Login was ever on, macOS still holds the registration. It is
  not a file this script can delete — SMAppService keeps it in the background
  task database. Turn it off in Vigil's settings before deleting the app, or
  afterwards in System Settings -> General -> Login Items & Extensions, where
  a registration whose app is gone shows up as an unnamed item you can remove
  with the minus button.

LOGIN

# ---------------------------------------------------------------------------
# 4. The root-owned half: the clamshell helper and its sudoers rule.
#
# Self-contained rather than delegating to install-clamshell.sh --uninstall.
# That script ships in two places, the checkout and the app bundle, and the
# whole problem this section exists for is that someone who downloaded the DMG
# and then trashed the app has neither.
# ---------------------------------------------------------------------------
say "Lid-closed helper (needs root)"
if [[ -e "$HELPER" || -e "$SUDOERS" ]]; then
  note "found          $HELPER"
  note "found          $SUDOERS"
  if (( DRY )); then
    note "would run      sudo rm -f '$SUDOERS' '$HELPER' && sudo /usr/bin/pmset -a disablesleep 0"
  else
    say
    note "About to run, as root:"
    note "  rm -f '$SUDOERS' '$HELPER'"
    note "  /usr/bin/pmset -a disablesleep 0"
    say
    # The sudoers rule goes first. If this is interrupted half-way, a helper
    # with no rule is inert; a rule with no helper is a NOPASSWD grant on a
    # path anything could later create.
    if sudo /bin/sh -c "rm -f '$SUDOERS' '$HELPER' && /usr/bin/pmset -a disablesleep 0"; then
      note "removed        the helper, the sudoers rule, and reset lid-close sleep"
    else
      say "  WARNING: that did not complete. Until it does, this is still in place:"
      say "    $SUDOERS"
      say "  It is a passwordless root grant on a path that no longer holds Vigil's"
      say "  helper. Remove it by hand: sudo rm -f '$SUDOERS' '$HELPER'"
    fi
  fi
else
  note "not installed  (nothing to do)"
fi

# Worth saying even when the helper was never installed: SIGKILL leaves this
# set with nothing to restore it, which is the one way a deleted Vigil can
# still be keeping a lid-closed Mac awake.
if [[ "$(/usr/bin/pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2}')" == "1" ]]; then
  say
  note "NOTE: SleepDisabled is still 1 — your Mac will not sleep with the lid shut."
  note "      Clear it with: sudo /usr/bin/pmset -a disablesleep 0"
fi
say

# ---------------------------------------------------------------------------
# 5. The backups Vigil made. Kept by default: they are copies of the user's
#    own files from before Vigil first edited them, and deleting someone's
#    only copy of their config during an uninstall is not a favour.
# ---------------------------------------------------------------------------
say "Backups Vigil made"
found_backup=0
for cfg in "${AGENT_CONFIGS[@]}" "$CODEX_CONFIG"; do
  b="$cfg.vigil-backup"
  [[ -e "$b" ]] || continue
  found_backup=1
  if (( BACKUPS )); then
    gone "backup" "$b"
  else
    note "kept           $b"
  fi
done
(( found_backup )) || note "none"
(( found_backup && ! BACKUPS )) && note "(pass --include-backups to delete these too)"
say

say "Finally: drag Vigil.app to the Trash if you have not already."
if (( DRY )); then
  say
  say "(--dry-run: nothing above was actually changed.)"
fi
