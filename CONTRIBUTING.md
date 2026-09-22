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
make test     # must pass
make lint     # must be clean
```

Run `make format` to fix formatting automatically.

## Where code belongs

- `Sources/VigilCore` — pure logic: event parsing, session tracking, the wake
  decision. No AppKit, no IOKit, no I/O. **Everything here must be unit-tested.**
- `Sources/Vigil` — the app: menu bar, IOKit, the socket bridge. Keep it thin;
  push decisions down into `VigilCore` where they can be tested.
- `Sources/VigilHelper` — the privileged helper (v2). Treat every change here as
  security-sensitive.

The split exists so the interesting logic is testable without a running app.
If you find yourself wanting to test something in `Sources/Vigil`, that is a
sign it belongs in `VigilCore`.

## Tests

We use [swift-testing](https://github.com/swiftlang/swift-testing), which needs
no dependency. Inject clocks rather than calling `Date()` directly — every
expiry rule should be testable without waiting.
