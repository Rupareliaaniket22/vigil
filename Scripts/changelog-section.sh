#!/usr/bin/env bash
#
# Print one version's section of CHANGELOG.md, for `gh release --notes-file`.
#
#   Scripts/changelog-section.sh 0.1.0
#
# The heading line itself is dropped — GitHub already shows the version — and
# so is everything from the next `## ` heading onwards.
#
# This exists because the obvious one-liner is wrong in two ways that both fail
# quietly. `sed -n '/## \[X\]/,/^## /p'` includes the *next* version's heading,
# because the range's end is searched for from the line after the start; and if
# there is no next heading it prints to the end of the file, which is how a
# release gets the entire changelog as its notes.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: $0 <version>   e.g. $0 0.1.0" >&2; exit 1; }

FILE="${CHANGELOG:-CHANGELOG.md}"
[[ -f "$FILE" ]] || { echo "error: $FILE not found" >&2; exit 1; }

# Held in a variable rather than written to `/tmp/vigil-notes.$$`. That name was
# both guessable and in a directory every account on the Mac can write to, and
# `>` follows a symlink — so another local user could have pointed it at a file
# of this user's and had this script truncate it. Nothing here needs to touch
# the disk at all, which is the better answer than a safer temp file.
SECTION="$(
  awk -v want="## [$VERSION]" '
    index($0, want) == 1 { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$FILE" | awk '
    # Trim blank lines at both ends without buffering the whole file twice.
    NF { blanks = 0; started = 1 }
    !NF && started { blanks++; next }
    started { while (blanks-- > 0) print ""; print }
  '
)"

if [[ -z "$SECTION" ]]; then
  echo "error: no '## [$VERSION]' section in $FILE." >&2
  echo "       Roll [Unreleased] into a version heading before releasing." >&2
  exit 1
fi

printf '%s\n' "$SECTION"
