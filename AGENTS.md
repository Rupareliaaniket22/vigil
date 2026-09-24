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
| Hook script bounded | `make hooktest` |
| Check formatting    | `make lint`    |
| Auto-fix formatting | `make format`  |
| Universal signed app| `make bundle`  |
| Panel lays out      | `make smoke`   |
| Full loop, live     | `make integration` |
| Build and launch    | `make run`     |

`make test && make lint` must both pass before any commit. `make integration`
launches a real app and checks the power assertion actually follows hook events
— run it when you touch the bridge, the model or the policy.

`make integration` is safe to run on the machine you are working on, and the
reason it needs saying is that for several commits it was not. Launching Vigil
is itself a write — `AppModel.start()` calls `maintainHooks()` — so a gate that
launched the app edited the four agents' settings files and `config.toml`
belonging to whoever ran it. Two things stop that now, and either would be
enough on its own: `CFFIXED_USER_HOME` points the app at a throwaway home
(which is why the script launches `Contents/MacOS/Vigil` directly — `open` goes
through LaunchServices and inherits none of this shell's environment), and
`-managesAgentHooks '<false/>'` turns automatic management off for that one
process through Foundation's argument domain, which is the only part that can
reach `UserDefaults` — a fake home cannot, because CFPreferences resolves the
real home through `cfprefsd`. The script's last three checks verify all of that
actually held. Do not remove them, and do not go back to `open`.

`make hooktest` drives `hooks/vigil-hook.sh` against a fake home and a stand-in
socket — run it when you touch the hook script. It sits outside `make test`
because its timing case has to watch a producer that keeps producing, and that
costs seconds by construction; `make test` is a sub-second loop people run
constantly and should stay one. It is not `make integration` either: that needs
a real signed app and real power assertions, and it stops any instance you have
running so that only one Vigil is in the assertion ledger. This needs none of
that.

Run `make format`
rather than hand-fixing style; `.swift-format` is the only source of truth for
formatting and its rules are deliberately not restated here.

`Scripts/uninstall.sh` removes everything Vigil puts on a machine. It is a
product feature, not a developer convenience — it ships inside the bundle,
because the root-owned half of a clamshell install can only be removed by a
script that otherwise goes into the Trash with the app. It deliberately does
not edit the four agents' config files: that is `HookConfiguration`'s job, in
Swift, with tests. It detects entries, reports them, and keeps the shared hook
script until they are gone — an entry pointing at a deleted script makes every
agent report a failed hook on every event, which is worse than leaving an inert
script behind. `--dry-run` changes nothing and is the way to try it.

`make release` runs `Scripts/release.sh`, which needs a Developer ID and a
stored notarytool profile. Nobody has run it end to end yet — it refuses
without credentials rather than half-shipping, but treat its first real run as
unproven. Signing happens locally, never in CI.

## Reading Vigil's own logs

Spell it `/usr/bin/log`, with the absolute path:

```sh
/usr/bin/log show --last 5m --info --debug --predicate 'subsystem == "io.github.rupareliaaniket22.vigil"'
/usr/bin/log stream --predicate 'subsystem == "io.github.rupareliaaniket22.vigil"' --level debug
```

**`--info --debug` is not optional on `log show`.** Almost everything Vigil
logs is `.info` — the bridge listening, a hold taken, a hold released, the
whole FlyingFox request trace — and `log show` omits `.info` and `.debug` from
the archive unless asked. Without those flags a perfectly healthy app prints a
bare header and nothing else, which is the same "Vigil logs nothing" wrong
conclusion the `zsh` builtin below produces, reached a different way.
`log stream` does not need them, because `--level debug` already says it.

**zsh has a `log` builtin, and it shadows `/usr/bin/log`.** A bare `log show …`
then does not run the logging tool at all — it fails with `zsh:log:1: too many
arguments`, and the obvious reading of that is "Vigil logs nothing". It is not;
the command never ran.

The trap is that whether you hit it depends on the shell, so a quick check in
your own terminal proves nothing:

```
$ zsh -f -c 'type log'        # a plain zsh, and any script
log is a shell builtin
$ zsh -ic 'type log'          # this machine's interactive shell
log is /usr/bin/log
```

Some interactive setups disable the builtin, which is why it can work when you
type it and fail from a script or an agent's shell — the contexts where a `log`
that silently does nothing is hardest to notice. Use the absolute path every
time and the question does not arise.

The subsystem is the bundle identifier, so it is whatever `BUNDLE_ID` in the
Makefile says. Running the binary outside a bundle falls back to the literal in
`Sources/Vigil/Vigil.swift`.

While looking for notification state, two more dead ends worth not repeating:
`~/Library/Preferences/com.apple.ncprefs.plist` does not exist on macOS 26, and
the `group.com.apple.usernoted/db2/db` sqlite file is empty. The live store is
`~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist`.

## Where code belongs

- **`Sources/VigilCore/`** — pure logic: event parsing, session tracking, the
  wake decision. **No `import AppKit`, no `import IOKit`, no file or network
  I/O.** Everything here is unit-tested.
- **`Sources/Vigil/`** — the app: `NSStatusItem` shell, IOKit power assertions,
  the Unix-socket bridge. Keep it thin.
- **`Sources/VigilHelper/`** — privileged root helper. **Does not exist**, and
  saying "not built" read as if it did. It is v2: `SMAppService` will not
  register a daemon without a matching Developer ID team, so nothing of it has
  been written. `XPCClamshellBackend` in `ClamshellController.swift` is a stub
  that reports `isAvailable = false` and throws — a named place for the work,
  not a start on it. Until then the scoped sudoers helper in `Scripts/` is the
  whole of the privileged path, and every change to it is security-sensitive.

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

- `hooks/vigil-hook.sh` — **Vigil's own product feature.** Agents run
  it on lifecycle events; it posts to Vigil's socket. Ordinary app code.
- `.claude/` — **Claude Code's config**, for people using Claude Code to develop
  Vigil. Different mechanism, same word. Don't conflate them.

## Conventions

- Commits and PRs: see [CONTRIBUTING.md](CONTRIBUTING.md).
- Changelog: Keep a Changelog + SemVer. User-visible changes go under
  `[Unreleased]`.
- Apache-2.0. Source files carry no per-file licence header — match that.
