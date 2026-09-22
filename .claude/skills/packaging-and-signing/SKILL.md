---
name: packaging-and-signing
description: Builds a universal arm64+x86_64 Vigil.app using Command Line Tools only and signs it in the correct order, without Xcode and without codesign --deep.
when_to_use: Use when running make bundle, editing Scripts/build-universal.sh or Scripts/bundle.sh, changing Info.plist or entitlements, or adding a bundled component (Sparkle, the helper) that needs its own signing step.
---

# Packaging and signing Vigil

Two Apple-platform footguns sit directly in the path of this task, and the
obvious command is wrong in both cases.

## Multi-arch: the obvious flag needs Xcode

`swift build --arch arm64 --arch x86_64` fails here:

```
error: xcbuild executable at '…/XCBuild.framework/…/xcbuild' does not exist
```

XCBuild ships only with full Xcode, which this project deliberately does not
require. `Scripts/build-universal.sh` instead runs two single-arch builds into
separate scratch paths and merges them with `lipo`. Extend that script rather
than reaching for the flag.

Verify with `lipo -info`; both slices must be present before signing.

## Signing: inside-out, and never `--deep`

Apple's own DTS guidance ("`--deep` Considered Harmful", TN2206) gives two
reasons it breaks nested bundles: it applies one identical set of entitlements
to every nested item, and it only finds code in nested locations it recognises.
Vigil's helper and app will need *different* entitlements, so `--deep` would
silently sign the helper wrong.

Sign innermost first, outer app last:

1. the privileged helper, with its own entitlements
2. Sparkle's nested code, deepest first — `Installer.xpc`, `Downloader.xpc`,
   `Autoupdate`, `Updater.app`, then the framework itself
3. the `.app` bundle

Anything sealed but not signed — the `Contents/Library/LaunchDaemons` plist —
must already be in place before step 3, because the outer signature seals it.

`--deep` *is* correct for verification, which is the one place the script uses it:

```sh
codesign --verify --deep --strict --verbose=2 dist/Vigil.app
```

That asymmetry trips people up: forbidden when signing, right when checking.

## Versions

`BUILD_VERSION` is `git rev-list --count HEAD`, and Sparkle compares
`CFBundleVersion` rather than the marketing string. It must never go backwards,
so rewriting published history would strand users on a version the appcast
thinks is newer than the update.

`IDENTITY` defaults to `-` (ad-hoc). A real release sets it to a Developer ID.
Note that an ad-hoc signature has no Team ID, which is why `SMAppService` refuses
to register the privileged helper in ad-hoc builds — that isn't a bug to debug.

## Not built yet

`make release` and `make dmg` reference `Scripts/release.sh`, which does not
exist. Notarization and appcast generation are unimplemented. Say so rather than
inventing the steps, and re-check before assuming it's still true.

CI runs `make bundle` unsigned on purpose, so no signing identity ever needs to
exist there. Releases are signed locally. Don't move signing into CI.

## Quick reference

| Task | Command |
| ---- | ------- |
| Universal binary | `Scripts/build-universal.sh` |
| Assemble + sign | `Scripts/bundle.sh` |
| Both | `make bundle` |
| Check slices | `lipo -info .build/universal/Vigil` |
| Check signature | `codesign -dv --verbose=2 dist/Vigil.app` |
| Verify nested | `codesign --verify --deep --strict dist/Vigil.app` |
