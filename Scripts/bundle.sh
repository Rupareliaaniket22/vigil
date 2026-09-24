#!/usr/bin/env bash
# Assemble, and sign, Vigil.app.
#
# Signing is inside-out and never uses --deep: --deep applies one set of
# entitlements to every nested item and misses unrecognised nested code.
# (Apple TN2206; Quinn, "--deep Considered Harmful".)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-Vigil}"
BUNDLE_ID="${BUNDLE_ID:-io.github.rupareliaaniket22.vigil}"
MARKETING_VERSION="${MARKETING_VERSION:-$(cat VERSION)}"
# Monotonic, and the field an updater would compare. Nothing compares it today:
# Vigil has no update mechanism (see docs/PLAN.md step 25). It is still the
# right value to set, because it has to be monotonic from the first release and
# cannot be retrofitted onto builds people already have.
BUILD_VERSION="${BUILD_VERSION:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# Ad-hoc by default; set IDENTITY to a Developer ID for a real release.
IDENTITY="${IDENTITY:--}"

DIST="dist"
APP="$DIST/$APP_NAME.app"
BIN=".build/universal/$APP_NAME"

[[ -f "$BIN" ]] || { echo "error: $BIN missing — run Scripts/build-universal.sh first" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/"{MacOS,Resources}

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

sed -e "s/__MARKETING_VERSION__/$MARKETING_VERSION/" \
    -e "s/__BUILD_VERSION__/$BUILD_VERSION/" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

# A placeholder left unsubstituted ships an app macOS cannot identify, and the
# failure is silent: launchd, UserDefaults and SMAppService all key off these.
if grep -q '__[A-Z_]*__' "$APP/Contents/Info.plist"; then
  echo "error: Info.plist still has an unsubstituted placeholder:" >&2
  grep -o '__[A-Z_]*__' "$APP/Contents/Info.plist" | sort -u >&2
  exit 1
fi

# The icon is generated from Scripts/make-icon.swift rather than checked in,
# so its design is reviewable in a diff instead of arriving as a binary blob.
if [[ ! -f "Resources/$APP_NAME.icns" ]]; then
  echo "==> generating icon"
  swift Scripts/make-icon.swift >/dev/null
  iconutil -c icns "Resources/$APP_NAME.iconset" -o "Resources/$APP_NAME.icns"
fi
cp "Resources/$APP_NAME.icns" "$APP/Contents/Resources/"

# The hook script ships inside the bundle; the installer copies it out to
# ~/.vigil/hooks so a moved or replaced app doesn't break an installed hook.
cp hooks/vigil-hook.sh "$APP/Contents/Resources/"

# The clamshell installer and its helper ship inside the bundle so the app can
# offer to install them itself. Someone who only downloaded the .app has no
# checkout to run them from.
#
# The uninstaller ships for the same reason and one more: it is the only thing
# that can take out the root-owned half of a clamshell install — a NOPASSWD
# sudoers rule and a helper in /Library/PrivilegedHelperTools — and the moment
# someone needs it most is the moment they are deleting the app. Tell them to
# run it *before* dragging Vigil to the Trash, because it goes in the Trash too.
cp Scripts/install-clamshell.sh Scripts/clamshell-helper.sh Scripts/uninstall.sh \
   "$APP/Contents/Resources/"

# FlyingFox is statically linked into the executable, and MIT requires its
# notice to be included in "all copies or substantial portions" — so it has to
# be in the thing we hand people, not only in the repo they did not clone.
cp LICENSE THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- sign, innermost first ---
# Nothing nested needs signing yet: the bundle holds one Mach-O and four data
# files. Anything nested that *is* code — a framework, the v2 privileged helper
# — gets its own codesign call here, before the one below. Never --deep.
#
# A secure timestamp is mandatory for notarisation: an upload signed with
# --timestamp=none comes back Invalid ("The signature does not include a secure
# timestamp"). It is equally mandatory that ad-hoc builds do *not* ask for one
# — there is no certificate to countersign, and every `make build` would then
# depend on Apple's timestamp server being reachable. So it follows IDENTITY.
if [[ "$IDENTITY" == "-" ]]; then
  TIMESTAMP_FLAG="--timestamp=none"
else
  TIMESTAMP_FLAG="--timestamp"
fi

echo "==> signing app bundle with identity: $IDENTITY ($TIMESTAMP_FLAG)"
codesign --force --sign "$IDENTITY" \
  --options runtime "$TIMESTAMP_FLAG" \
  --entitlements "Resources/$APP_NAME.entitlements" \
  "$APP"

# The signature must carry what notarisation requires, and "we passed the right
# flag" is not the same claim as "the signature has it". Read it back.
if [[ "$IDENTITY" != "-" ]]; then
  codesign -dvv "$APP" 2>&1 | grep -q "^Timestamp=" \
    || { echo "error: signed with a Developer ID but no secure timestamp landed; notarisation would reject this" >&2; exit 1; }
fi

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
echo
echo "built: $APP  (v$MARKETING_VERSION build $BUILD_VERSION)"
