# Security Policy

## Reporting

Report vulnerabilities through GitHub's private advisory reporting rather than a
public issue.

## Threat model

Vigil's normal operation needs **no elevated privileges**. The wake lock uses
`IOPMAssertionCreateWithName`, available to any user process.

Two components deserve scrutiny:

### The hook bridge

Agent hooks post JSON to a Unix domain socket under
`~/Library/Application Support/Vigil/`. A Unix socket is used deliberately
instead of a localhost TCP port: loopback TCP is reachable by **any** local user
account, while a socket file is constrained by filesystem permissions and gives
us a kernel-verified peer uid via `getpeereid`.

All payloads are treated as untrusted input. Malformed events are rejected
rather than guessed at.

### Lid-closed support (opt-in)

Keeping the Mac awake with the lid shut requires clearing `SleepDisabled` on
`IOPMrootDomain`, which needs root. Two backends exist:

- **sudoers backend** — a root-owned helper at `/usr/local/libexec/vigil-clamshell`,
  permitted by a scoped `/etc/sudoers.d` rule to run exactly two fixed argument
  vectors. Specifically:

  ```
  <user> ALL=(root) NOPASSWD: /usr/local/libexec/vigil-clamshell on, \
                              /usr/local/libexec/vigil-clamshell off
  ```

  The grant is deliberately narrow. No wildcard, because `vigil-clamshell *`
  would let any argument through and the helper is only safe because its input
  is fixed. The helper takes exactly one argument, accepts only `on` or `off`,
  rejects everything else with exit 64, and never builds a command from its
  input. It calls `pmset -a disablesleep` and nothing else.

  The installer validates the generated rule with `visudo -cqf` before moving
  it into place — a malformed file in `sudoers.d` can lock you out of `sudo`
  entirely. It installs the helper root-owned and mode 0755, and Vigil refuses
  to invoke a helper that is not root-owned or that is group- or
  world-writable, since a NOPASSWD rule pointing at a writable file is a root
  shell.

  Note that `pmset` prints "must be run as root" and still exits 0, so the
  helper reads `SleepDisabled` back and confirms it matches what was asked
  rather than trusting the exit status.
- **XPC helper backend** (v2) — an `SMAppService` daemon. Registration requires a
  matching Developer ID team, and the listener must set a code-signing
  requirement so arbitrary local processes cannot drive it.

Lid-closed mode is off by default and must be explicitly enabled.

### Failure mode we care most about

A Mac left unable to sleep in a bag will drain its battery and run hot. Four
things guard against it:

- **A battery floor**, checked before intent. No amount of agent activity or
  manual override beats it.
- **Session expiry.** An agent that dies without reporting stops counting after
  five minutes, so a crashed agent cannot pin the Mac awake indefinitely.
- **Restore on quit**, via `applicationWillTerminate`.
- **Restore on launch and on signals.** `applicationWillTerminate` does not run
  on a crash, a force-quit or a `kill`, so Vigil also clears the lid-close flag
  every time it starts, and installs `SIGINT`/`SIGTERM`/`SIGHUP` handlers that
  restore it before dying.

One gap remains: if Vigil is killed with `SIGKILL` (which cannot be trapped) and
never relaunched, lid-close sleep stays disabled until something restores it.
Run `sudo ./Scripts/install-clamshell.sh --uninstall`, or
`sudo pmset -a disablesleep 0`, to clear it by hand.
