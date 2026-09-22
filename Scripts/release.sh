#!/usr/bin/env bash
#
# Cut a signed, notarized release.
#
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=vigil-notary \
#   MARKETING_VERSION=1.0.0 \
#   make release
#
# Requires a paid Apple Developer ID. Everything up to signing works without
# one — `make bundle` produces a runnable ad-hoc app — but Gatekeeper will
# refuse it on anyone else's Mac, and SMAppService refuses to register a
# privileged helper without a matching Team ID.
#
# Store the notary credentials once:
#   xcrun notarytool store-credentials vigil-notary \
#     --key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>
#
# Signing happens locally, never in CI, so the private key never leaves this
# machine.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="${APP_NAME:-Vigil}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
IDENTITY="${IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

DIST=dist
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME.zip"
DMG="$DIST/$APP_NAME-$MARKETING_VERSION.dmg"

die() { echo "error: $*" >&2; exit 1; }

[[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] || die "set IDENTITY to a Developer ID Application certificate"
[[ -n "$NOTARY_PROFILE" ]] || die "set NOTARY_PROFILE to a stored notarytool profile"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || die "identity not found in keychain: $IDENTITY"

echo "==> building"
IDENTITY="$IDENTITY" MARKETING_VERSION="$MARKETING_VERSION" make bundle

echo "==> verifying the signature we just applied"
# --deep is correct for verification and forbidden for signing. See
# Apple TN2206 and Quinn, "--deep Considered Harmful".
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> checking the app actually launches"
VIGIL_SMOKE=1 "$APP/Contents/MacOS/$APP_NAME" || die "smoke test failed; not shipping this"

echo "==> notarizing the app"
# Notarize the app itself as well as the DMG. Notarizing only the outer
# container means the ticket staples to the DMG alone, so a user who drags the
# app out and launches it offline still sees a Gatekeeper warning.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> building the disk image from the stapled app"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> final check, as Gatekeeper would see it"
spctl --assess --type open --context context:primary-signature -vv "$DMG" || true
xcrun stapler validate "$DMG"

echo
echo "ready: $DMG"
echo "next:  gh release create v$MARKETING_VERSION $DMG --notes-file <(sed -n '/## \\[Unreleased\\]/,/^## /p' CHANGELOG.md)"
