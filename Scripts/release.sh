#!/usr/bin/env bash
#
# Cut a signed, notarized release.
#
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=vigil-notary \
#   make release
#
# The version comes from the `VERSION` file and nowhere else. To cut a new one,
# edit `VERSION` and commit it — do not pass MARKETING_VERSION here.
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
MARKETING_VERSION="${MARKETING_VERSION:-$(cat VERSION)}"
IDENTITY="${IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

DIST=dist
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME.zip"
DMG="$DIST/$APP_NAME-$MARKETING_VERSION.dmg"
STAGE="$DIST/dmg-root"

die() { echo "error: $*" >&2; exit 1; }

# Submit and insist on "Accepted".
#
# `notarytool submit --wait` reports that the *submission* completed; a build
# the service rejected still finishes the poll, and the next line that cares is
# `stapler`, which fails with "could not find a ticket" and says nothing about
# why. Read the status back and print the log, which names the actual rejection
# (a missing secure timestamp, an unhardened binary, an unsigned nested item).
#
# --timeout so an unreachable service fails the release rather than parking it
# overnight on a terminal nobody is watching.
notarize() {
  local path="$1" json id status
  json="$(xcrun notarytool submit "$path" \
    --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m \
    --output-format json)" || die "notarytool submit failed for $path"
  id="$(/usr/bin/plutil -extract id raw -o - - <<<"$json" 2>/dev/null || true)"
  status="$(/usr/bin/plutil -extract status raw -o - - <<<"$json" 2>/dev/null || true)"
  echo "    submission $id: $status"
  if [[ "$status" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization was not accepted for $path (status: ${status:-unknown})"
  fi
}

[[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] || die "set IDENTITY to a Developer ID Application certificate"
[[ -n "$NOTARY_PROFILE" ]] || die "set NOTARY_PROFILE to a stored notarytool profile"
# -F: the identity is a literal string, not a regular expression. A Developer ID
# common name can contain characters grep would otherwise read as syntax.
security find-identity -v -p codesigning | grep -qF "$IDENTITY" || die "identity not found in keychain: $IDENTITY"

# A release nobody can point at a commit is not auditable, and auditability is
# the pitch. CFBundleVersion comes from `git rev-list --count HEAD`, so a dirty
# tree ships a build whose stated provenance is a lie about what is in it.
git diff --quiet && git diff --cached --quiet \
  || die "working tree is dirty; commit or stash before cutting a release"
[[ -z "$(git ls-files --others --exclude-standard)" ]] \
  || die "untracked files present; commit, remove or ignore them before cutting a release:
$(git ls-files --others --exclude-standard)"

# `VERSION` is the single source of truth, and an override defeats the whole
# point of there being one. This script's own usage example used to pass
# `MARKETING_VERSION=1.0.0`, which produces a release that disagrees with
# itself in a way nothing downstream can catch: the binary, the DMG name, the
# changelog section looked up and the tag suggested at the end all come from
# the override, while the commit the tag points at — checked clean two lines
# above, so it is the commit people will read — still says 0.1.0 in `VERSION`.
# Accepted only when it agrees, so `MARKETING_VERSION=$(cat VERSION)` in a
# wrapper keeps working and a typo does not.
FILE_VERSION="$(cat VERSION)"
[[ "$MARKETING_VERSION" == "$FILE_VERSION" ]] || die \
  "MARKETING_VERSION is $MARKETING_VERSION but the VERSION file says $FILE_VERSION.
Edit VERSION and commit it; that file is what a release is named after."

# Everything below this line costs two notarisation round trips, and
# `notarytool --timeout 30m` means that is up to an hour on a terminal nobody is
# watching. So every condition that can be known now is checked now, rather than
# discovered by the instructions printed at the end being impossible to follow.
#
# The release notes come from CHANGELOG.md, and `[Unreleased]` is not a release:
# rolling it into a version heading is part of cutting one, not paperwork to do
# afterwards. Checked with the same script that will read it, so this cannot
# pass while the real thing fails.
Scripts/changelog-section.sh "$MARKETING_VERSION" >/dev/null 2>&1 \
  || die "CHANGELOG.md has no '## [$MARKETING_VERSION]' section.
Roll [Unreleased] into a '## [$MARKETING_VERSION] - $(date +%F)' heading, commit, and run this again."

# A tag that already exists means this version has been cut before. Rebuilding
# it produces a *different* binary — CFBundleVersion is the commit count, which
# has moved — under a version number people have already downloaded.
#
# `if`, not `cmd && die`: under `set -e` an `&&` list whose left side fails
# takes the whole script down, so the common case — the tag correctly does not
# exist yet — would abort the release it was meant to allow.
if git rev-parse -q --verify "refs/tags/v$MARKETING_VERSION" >/dev/null; then
  die "tag v$MARKETING_VERSION already exists; bump VERSION before cutting another release"
fi

# Captured before the build, and printed in the tag command at the end.
#
# `CFBundleVersion` is `git rev-list --count HEAD`, fixed at the moment the
# build runs. The tag is created by hand afterwards, from instructions printed
# at the end of a script whose slowest step is two notarisation round trips —
# up to an hour. Anything committed in that window moves `HEAD`, so a bare
# `git tag -s v0.1.0` would name a commit the shipped binary was not built
# from, and the count baked into it would belong to a different tree. The
# clean-tree check above makes that narrow; it does not make it impossible,
# and the whole pitch is that a release can be pointed at a commit.
BUILT_AT="$(git rev-parse --short HEAD)"

echo "==> building"
echo "    commit $BUILT_AT"
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
notarize "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> the app, as Gatekeeper will see it on someone else's Mac"
spctl --assess --type execute --verbose=4 "$APP" \
  || die "Gatekeeper rejects the app; not shipping this"

echo "==> building the disk image from the stapled app"
# Staged rather than pointing hdiutil at the .app: `-srcfolder Vigil.app`
# produces a volume whose only item is the app, with nowhere to drag it. The
# overwhelmingly common thing to do with that window is double-click the app
# where it sits, which runs it from a read-only volume under App Translocation
# — so Launch at Login registers a path that vanishes on eject, and the app
# dies mid-run when the disk image is unmounted.
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$APP_NAME $MARKETING_VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> final check, as Gatekeeper would see it"
# Not `|| true`. Shipping a disk image Gatekeeper refuses is the single failure
# this script exists to prevent, so it is the last thing that may be ignored.
spctl --assess --type open --context context:primary-signature -vv "$DMG" \
  || die "Gatekeeper rejects the disk image; not shipping this"
xcrun stapler validate "$DMG"

echo "==> confirming the image mounts, drags, and still passes inside"
MOUNT="$(mktemp -d)"
# The trap is armed before the attach, not after: `hdiutil attach` can succeed
# and still leave the script to die on the next line, and an interrupted release
# must not leave a volume mounted. Detaching something that was never attached
# is already tolerated by the `|| true`.
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$MOUNT"' EXIT
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
[[ -d "$MOUNT/$APP_NAME.app" ]] || die "disk image has no $APP_NAME.app"
[[ -L "$MOUNT/Applications" ]] || die "disk image has no /Applications symlink to drag to"

# Everything above assessed `dist/Vigil.app` — the copy this machine built. This
# assesses the copy the user actually receives, which is the one `ditto` put
# inside the image, and it is not the same claim: a ticket that failed to travel
# through `ditto`, or a seal broken by staging, shows up here and nowhere else.
# Offline Gatekeeper has no fallback for a missing staple, so the check that
# matters is the stapled one.
xcrun stapler validate "$MOUNT/$APP_NAME.app" \
  || die "the app inside the disk image is not stapled; an offline user would see a Gatekeeper warning"
spctl --assess --type execute --verbose=4 "$MOUNT/$APP_NAME.app" \
  || die "Gatekeeper rejects the app inside the disk image; not shipping this"

hdiutil detach "$MOUNT" -quiet
trap - EXIT
rm -rf "$MOUNT"

# The zip existed only to hand the app to the notary service. Leaving it beside
# the DMG in dist/ invites uploading the unstapled one to the release.
rm -f "$ZIP"

echo
echo "ready: $DMG"
echo
echo "next (the changelog section and the free tag name were both checked before"
echo "the build, so these three should run clean). The tag names $BUILT_AT — the"
echo "commit this binary was built from — rather than wherever HEAD has got to:"
echo
echo "  git tag -s v$MARKETING_VERSION $BUILT_AT -m 'Vigil $MARKETING_VERSION' && git push --tags"
# dist/, not /tmp: /tmp is world-writable and the name is guessable, and the
# notes end up beside the disk image they describe rather than in a directory
# that is cleared out from under you.
echo "  Scripts/changelog-section.sh $MARKETING_VERSION > $DIST/notes.md"
echo "  gh release create v$MARKETING_VERSION $DMG --title 'Vigil $MARKETING_VERSION' --notes-file $DIST/notes.md"
