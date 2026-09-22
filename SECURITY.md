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
rather than guessed at, and bodies over 64 KB are refused with 413 before being
read into memory — a real hook event is a few hundred bytes, so anything near
that limit is either a broken hook or something probing the socket.

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

- **Actually asking the Mac to sleep** when a guardrail fires. macOS only
  re-evaluates clamshell sleep on a lid open or close event, so with the lid
  already shut, clearing the flag leaves the machine merely *permitted* to
  sleep with nothing asking it to — it keeps draining. A well-regarded project
  with twenty thousand stars shipped exactly this bug and drained from 20% to
  1%. Vigil's helper takes a `sleep` verb that restores the flag and requests
  sleep in one step, used only when a safety rule forced the release and never
  when work merely finished.
- **A thermal ceiling**, checked before everything else and applied on mains
  power too. A plugged-in Mac held awake inside a closed bag is the hottest
  case there is, so heat outranks even a manual hold. Defaults to releasing at
  macOS's "serious" thermal state rather than "critical" — by the time macOS
  says critical it is already throttling hard.
- **A battery floor**, checked before intent. No amount of agent activity or
  manual override beats it.
- **Session expiry.** An agent that dies without reporting stops counting after
  five minutes, so a crashed agent cannot pin the Mac awake indefinitely.
- **Restore on quit**, via `applicationWillTerminate`.
- **Restore on launch and on signals.** `applicationWillTerminate` does not run
  on a crash, a force-quit or a `kill`, so Vigil also clears the lid-close flag
  every time it starts, and installs `SIGINT`/`SIGTERM`/`SIGHUP` handlers that
  restore it before dying.

Vigil also reconciles against the system rather than its own cached belief:
`SleepDisabled` is read back from `IOPMrootDomain` (which needs no privileges to
read) before every change, so a flag cleared by macOS underneath us — a
power-source change is the case other implementations keep filing bugs about —
is noticed instead of silently disagreed with.

One gap remains: if Vigil is killed with `SIGKILL` (which cannot be trapped) and
never relaunched, lid-close sleep stays disabled until something restores it.
Run `sudo ./Scripts/install-clamshell.sh --uninstall`, or
`sudo pmset -a disablesleep 0`, to clear it by hand.
