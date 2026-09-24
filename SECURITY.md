# Security Policy

## Reporting

Report vulnerabilities through GitHub's private advisory reporting rather than a
public issue.

## Threat model

Vigil's normal operation needs **no elevated privileges**. The wake lock uses
`IOPMAssertionCreateWithName`, available to any user process.

Three components deserve scrutiny. The third has by far the largest blast
radius, and unlike the other two it is on by default.

### Writing into other programs' config files

Vigil edits four other programs' configuration, automatically, at launch, with
no prompt. This is the part of Vigil to read closely.

`AppModel.start()` calls `maintainHooks()`, which for every agent it finds
writes a hook entry into that agent's own settings file:

| File | What Vigil writes |
| :-- | :-- |
| `~/.claude/settings.json` | Hook entries invoking `~/.vigil/hooks/vigil-hook.sh` |
| `~/.codex/hooks.json` | The same |
| `~/.gemini/settings.json` | The same |
| `~/.cursor/hooks.json` | The same |
| `~/.codex/config.toml` | A `[hooks.state."…"]` trust record for those entries |

The same pass runs again every time the menu bar panel is opened. Nobody is
asked, on either occasion. The argument for that is in `HookMaintenance`: a
prompt that fires on every release is a prompt people learn to click through,
and installing hooks is the whole of what this app does. The argument against
it is that a program which edits other programs' configuration unbidden is
exactly the shape of thing a threat model exists to describe, so here is the
description.

**Every write is bounded, in four separate ways:**

- **Backups.** The original file is copied to `<file>.vigil-backup` before the
  first edit, once — not on every write, or the backup would become Vigil's own
  output after the second one.
- **Atomic replacement**, following a symlink to its target first, carrying the
  original file mode across, and refusing outright to touch a file the user has
  made read-only.
- **Refusal over guessing.** A settings file that will not parse, one holding
  JSON comments, or one whose hook entries are in a shape Vigil does not
  recognise is reported to the user and left exactly as it was. Vigil never
  overwrites an entry belonging to another tool.
- **A byte-for-byte bound on what may be approved.** This is the one that
  matters most, because approving a hook is the step that makes a hook *run*.

#### The bound on the trust record

Codex will not run a hook it has no matching `trusted_hash` for. Vigil writes
that record for itself, so the record is the only thing standing between "Vigil
wrote an entry" and "Codex executes it".

What bounds it is `CodexTrustWriter.selfWrittenRecords`, and it is one rule:
**a record is written only for an entry whose command is byte-for-byte the
string `HookConfiguration.command(scriptPath:integration:registration:)`
produces today for that integration**, under the event it is filed under, with
that registration's matcher and the timeout Codex would assume. Byte-for-byte
is meant literally — the comparison is on UTF-8 bytes, not Swift's `==`, which
is Unicode canonical equivalence and once admitted a command naming the same
home directory in the other normal form. Anything that fails the comparison
gets no record, stays untrusted, and is shown to the user with a pointer to
Codex's own `/hooks` command.

So Vigil cannot approve an entry it did not itself write. An attacker who adds
a hook to `hooks.json` gains nothing from Vigil: their entry fails the
comparison and Codex goes on refusing it.

#### What that bound does not cover

- **It does not cover the script.** Codex's `trusted_hash` is computed over the
  hook *entry* — event, command string, timeout, matcher — and not over the
  contents of the file the command points at. `~/.vigil/hooks/vigil-hook.sh`
  never appears in the hashed identity. **Anyone who can write that file gets
  their code run inside every agent session on the machine, and neither Codex's
  gate nor Vigil's bound will notice**, because the hash has never covered it
  and could not. The script lives under the user's home directory at mode 0755;
  it is protected by filesystem permissions and by nothing else. This is not a
  weakness Vigil's self-approval introduced — the gate never covered it — but
  it is the thing a reader of "Vigil approves its own hooks" most needs to know.
- **It does not cover the installation.** The bound governs what Vigil may
  *approve*, not what Vigil may *write*. Hook entries go into all four files
  with no prompt and no equivalent narrowing beyond "don't touch what isn't
  ours".
- **It does not cover consent.** Nothing here is a permission check. The
  defence against an unwanted write is disclosure and a switch — the panel
  names the agents it set up, the settings row says when Vigil recorded a host's
  approval, and **Set up and update agent hooks automatically** turns the whole
  pass off — not a dialog.
- **It does not reach a record Vigil did not write.** Removing Vigil's hooks
  now also removes the trust records Vigil wrote, so an undo is a real undo and
  a later reinstall is not silently pre-approved. But a record filed under one
  of Vigil's keys holding a hash Vigil did not write belongs to whoever wrote
  it, and Vigil leaves it alone rather than guessing.
- **It says nothing about the other three hosts.** Claude Code, Gemini CLI and
  Cursor have no trust gate. A hook entry in their settings files runs because
  it is there.

`CodexTrustWriter` refuses to edit `config.toml` at all when it meets a shape
it cannot rewrite unambiguously — a dotted key under `[hooks.state]`, an inline
table, an array of tables, a value it cannot find the end of. The reasoning is
that a `config.toml` Codex cannot parse does not cost the user their wake lock,
it costs them Codex. The same refusal governs removal.

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

- **sudoers backend** — a root-owned helper at `/Library/PrivilegedHelperTools/vigil-clamshell`,
  permitted by a scoped `/etc/sudoers.d` rule to run exactly three fixed
  argument vectors. Specifically:

  ```
  <user> ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/vigil-clamshell on, \
                              /Library/PrivilegedHelperTools/vigil-clamshell off, \
                              /Library/PrivilegedHelperTools/vigil-clamshell sleep
  ```

  The grant is deliberately narrow. No wildcard, because `vigil-clamshell *`
  would let any argument through and the helper is only safe because its input
  is fixed. The helper takes exactly one argument, accepts only `on`, `off` or
  `sleep`, rejects everything else with exit 64, and never builds a command from
  its input. It calls `pmset -a disablesleep` — and, for `sleep` alone,
  `pmset sleepnow` — and nothing else. Why a third verb is needed at all is in
  "Failure mode we care most about" below.

  The installer validates the generated rule with `visudo -cqf` before moving
  it into place — a malformed file in `sudoers.d` can lock you out of `sudo`
  entirely — and builds it in a temporary file outside `sudoers.d` so a partial
  write is never readable by `sudo`.

  The helper lives in `/Library/PrivilegedHelperTools`, Apple's designated
  location for privileged helpers, rather than `/usr/local`. Homebrew chowns
  `/usr/local` to the user on Intel Macs, and renaming a directory needs write
  permission only on its *parent* — so a writable ancestor would let anything
  running as you substitute the helper and inherit the passwordless grant.
  Before installing, every ancestor of the helper path is checked to be
  root-owned and not group- or world-writable, and installation is refused
  otherwise. The invoking username is also validated, because `visudo` checks
  syntax rather than intent. It installs the helper root-owned and mode 0755, and Vigil refuses
  to invoke a helper that is not root-owned or that is group- or
  world-writable, since a NOPASSWD rule pointing at a writable file is a root
  shell.

  Note that `pmset` prints "must be run as root" and still exits 0, so the
  helper reads `SleepDisabled` back and confirms it matches what was asked
  rather than trusting the exit status.
- **XPC helper backend** (v2) — an `SMAppService` daemon. Registration requires a
  matching Developer ID team, and the listener must set a code-signing
  requirement so arbitrary local processes cannot drive it.

Lid-closed mode is off by default and must be explicitly enabled. Turning it on
installs the helper through macOS's own authorization prompt rather than asking
you to paste a `sudo` command into a terminal — the dialog names the app and
requires your password, and it avoids teaching the habit of running privileged
commands copied from a README. The setting is only stored once the helper is
verified present, so a cancelled or failed install leaves the switch off rather
than on and inert.

Without a Developer ID this is the honest route; a signed build would use
`SMAppService` and a real XPC helper instead.

### Failure mode we care most about

A Mac left unable to sleep in a bag will drain its battery and run hot. Six
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
- **Restore on quit**, via `applicationWillTerminate`. It re-reads
  `SleepDisabled` rather than trusting what Vigil last set, so a flag that
  drifted — or one a still-running worker had just set without recording it —
  is cleared on the way out instead of being left behind.
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
Run `sudo pmset -a disablesleep 0` to clear it by hand.

### Removing the privileged parts

`Scripts/uninstall.sh` takes out the helper, the sudoers rule and the
`SleepDisabled` flag together, and it is the path to prefer: it asks for your
password once, for that step alone, and says what it is about to run as root
before it runs it. It also checks `SleepDisabled` afterwards and tells you if
something still has it set.

The narrower `./Scripts/install-clamshell.sh --uninstall` does the same three
things and nothing else.

Both ship in two places and they are the same files: a checkout, and
`/Applications/Vigil.app/Contents/Resources/` in an installed app. Someone who
downloaded Vigil rather than cloning it has only the second — **and once the
app is in the Trash, neither.** A sudoers rule granting passwordless root on a
path whose binary you have just deleted is the worst of the leftovers, so do
this before deleting the app, not after.
