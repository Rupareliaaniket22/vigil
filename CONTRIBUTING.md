# Contributing

## Getting set up

You need macOS 14+ and the Command Line Tools. **Full Xcode is not required** —
the entire build, sign and package path works without it.

```sh
xcode-select --install
make build && make test
```

If you do have Xcode, everything still works; nothing here depends on it.

## Before opening a pull request

```sh
make test         # must pass
make lint         # must be clean
make integration  # if you touched the bridge, model or policy
```

`make integration` launches a real app and drives it through the whole loop,
checking that macOS's power state actually follows. The unit tests cover the
decision logic and `make smoke` covers the panel building; this covers the part
neither can.

It is safe to run on your own machine, and that took work: Vigil installs hooks
into your agents' config files the moment it launches, so for a while this gate
edited `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.codex/config.toml`,
`~/.gemini/settings.json` and `~/.cursor/hooks.json` on whoever ran it. It now
launches the binary directly against a throwaway home with automatic hook
management switched off for that one process, and its last three checks confirm
your five real files and Vigil's own record of what it has set up came through
untouched. If you change how the app is launched there, keep those checks — they
are what makes the rest of the script safe to ask people to run.

Run `make format` to fix formatting automatically.

## Where code belongs

- `Sources/VigilCore` — pure logic: event parsing, session tracking, the wake
  decision. No AppKit, no IOKit, no I/O. **Everything here must be unit-tested.**
- `Sources/Vigil` — the app: menu bar, IOKit, the socket bridge. Keep it thin;
  push decisions down into `VigilCore` where they can be tested.
- `Sources/VigilHelper` — the privileged XPC helper. Does not exist yet: it is
  v2, and it needs a Developer ID before `SMAppService` will register it. Until
  then the scoped sudoers helper in `Scripts/` fills the role. Treat every
  change to either as security-sensitive.

The split exists so the interesting logic is testable without a running app.
If you find yourself wanting to test something in `Sources/Vigil`, that is a
sign it belongs in `VigilCore`.

## Tests

We use [swift-testing](https://github.com/swiftlang/swift-testing), which needs
no dependency. Inject clocks rather than calling `Date()` directly — every
expiry rule should be testable without waiting.
