# Vigil — agent instructions

Vigil is a macOS menu bar app that holds a wake lock while AI coding agents are
working, and releases it the moment they stop.

This file is the *how* for whoever is editing this repo, human or agent. The
*why* lives elsewhere: [README.md](README.md) for what the project is,
[CONTRIBUTING.md](CONTRIBUTING.md) for workflow, [SECURITY.md](SECURITY.md) for
the threat model, [DESIGN.md](DESIGN.md) for visual language.

## Build, test, lint

Command Line Tools only. **Never assume Xcode is installed** and never generate
an `.xcodeproj` — building without Xcode is a deliberate contributor benefit,
not an oversight.

| Task                | Command        |
| ------------------- | -------------- |
| Debug build         | `make build`   |
| Run tests           | `make test`    |
| Check formatting    | `make lint`    |
| Auto-fix formatting | `make format`  |
| Universal signed app| `make bundle`  |
| Panel lays out      | `make smoke`   |
| Full loop, live     | `make integration` |
| Build and launch    | `make run`     |

`make test && make lint` must both pass before any commit. `make integration`
launches a real app and checks the power assertion actually follows hook events
— run it when you touch the bridge, the model or the policy. Run `make format`
rather than hand-fixing style; `.swift-format` is the only source of truth for
formatting and its rules are deliberately not restated here.

`make release` runs `Scripts/release.sh`, which needs a Developer ID and a
stored notarytool profile. Nobody has run it end to end yet — it refuses
without credentials rather than half-shipping, but treat its first real run as
unproven. Signing happens locally, never in CI.

## Where code belongs

- **`Sources/VigilCore/`** — pure logic: event parsing, session tracking, the
  wake decision. **No `import AppKit`, no `import IOKit`, no file or network
  I/O.** Everything here is unit-tested.
- **`Sources/Vigil/`** — the app: `NSStatusItem` shell, IOKit power assertions,
  the Unix-socket bridge. Keep it thin.
- **`Sources/VigilHelper/`** — privileged root helper (v2, not built). Every
  change here is security-sensitive.

Wanting to test something in `Sources/Vigil` means the logic belongs in
`VigilCore`. Move it down rather than building a test seam in the app layer.

## Concurrency

All targets use Swift 6 language mode.

- UI-facing classes are `@MainActor`: `PowerAssertion`, `EventBridge`,
  `ClamshellController`, `AppDelegate`.
- **The bridge's route handlers deliberately run off the main actor.** Don't
  "fix" this by marking them `@MainActor` — that would serialize socket I/O onto
  the UI thread. Hop back explicitly with `await MainActor.run { … }`, the way
  `EventBridge.swift` already does.
- `VigilCore` types are `Sendable` value types on purpose. Keep new ones that way.
- `@preconcurrency import` silences a warning; it adds no thread safety. If an
  unannotated C API needs it, add real synchronization at that boundary too.

## Testing

swift-testing (`@Suite`, `@Test`, `#expect`) — not XCTest, and no extra
dependency is needed.

Inject the clock via `now:` parameters instead of calling `Date()` inside logic
under test. Every expiry and staleness rule must be testable without waiting.
`WakePolicyTests.swift` is the pattern to copy.

## Security — hard rules

These are invariants. A violation is a regression even when tests pass.

- **Never use `codesign --deep`.** It applies one set of entitlements to every
  nested item and misses unrecognized nested code. Sign inside-out, as
  `Scripts/bundle.sh` does. `--deep` is fine for *verifying* only.
- **Never commit signing material** — private keys, `.p12`, provisioning
  profiles. These are gitignored; don't work around that.
- **CI never signs.** `make bundle` runs unsigned in CI so no signing identity
  need exist there. Don't add one to make CI "more realistic".
- **Never weaken code-signing or peer validation to make a test pass.** Mock the
  peer instead. A signature check alone doesn't stop library injection into an
  already-trusted process, so loosening it is worse than it looks.
- The wake hold needs no privileges at all. Only lid-closed support touches
  root: the sudoers helper must stay root-owned and non-writable by group or
  world, with no wildcards or shell interpolation in its rule. Treat changes to
  `SudoersClamshellBackend` with the scrutiny of a sandbox escape.

## Two unrelated things are called "hooks"

- `hooks/claude-code/vigil-hook.sh` — **Vigil's own product feature.** Agents run
  it on lifecycle events; it posts to Vigil's socket. Ordinary app code.
- `.claude/` — **Claude Code's config**, for people using Claude Code to develop
  Vigil. Different mechanism, same word. Don't conflate them.

## Conventions

- Commits and PRs: see [CONTRIBUTING.md](CONTRIBUTING.md).
- Changelog: Keep a Changelog + SemVer. User-visible changes go under
  `[Unreleased]`.
- Apache-2.0. Source files carry no per-file licence header — match that.
