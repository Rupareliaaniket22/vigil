#!/usr/bin/env bash
# Assemble, and sign, Vigil.app.
#
# Signing is inside-out and never uses --deep: --deep applies one set of
# entitlements to every nested item and misses unrecognised nested code.
# (Apple TN2206; Quinn, "--deep Considered Harmful".)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-Vigil}"
BUNDLE_ID="${BUNDLE_ID:-dev.vigil.app}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
# Monotonic, and what Sparkle actually compares.
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
    Resources/Info.plist > "$APP/Contents/Info.plist"

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
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- sign, innermost first ---
# (Sparkle.framework and the privileged helper get signed here, before the app,
#  once they are added.)
echo "==> signing app bundle with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" \
  --options runtime --timestamp=none \
  --entitlements "Resources/$APP_NAME.entitlements" \
  "$APP"

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
echo
echo "built: $APP  (v$MARKETING_VERSION build $BUILD_VERSION)"
