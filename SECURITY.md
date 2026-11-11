# Security

Procopticon inspects and controls other processes, and can do so as root. This page says how to
report a problem, what the privileged parts are meant to guarantee, and what they don't.

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

- Use **Report a vulnerability** on the repository's
  [Security tab](https://github.com/nicholas-ochoa/Procopticon/security/advisories/new)
  (GitHub private vulnerability reporting).

Say what you found, how to reproduce it, and which version or commit you tested. You should hear
back within a week. Procopticon is maintained by one person in spare time, so a fix can take longer
than that; you'll be told what to expect, and credited in the fix unless you'd rather not be.

Only the latest release and the `main` branch are supported.

## How elevation works

Procopticon runs in one of three modes (see *Privileges* in the README):

- **Standard.** Everything runs as you. Nothing here is privileged.
- **Elevated helper.** After you authorize in the macOS administrator dialog (or without a dialog,
  if your account has passwordless `sudo`), `procopticon-helper` runs as root until the app quits.
  Root never runs the helper inside the application bundle: it copies it into
  `/var/run/procopticon`, a directory only root can write to, checks that the copy is signed by
  the same developer team as the running app, and runs the copy. The helper listens on a Unix
  socket in that directory. The socket is owned by you with mode `0600`, and the helper accepts a
  connection only when the peer is the app process that started it (checked by PID and UID before
  any request is read).
- **Root.** The whole app runs as root (`sudo …/Procopticon` or *File ▸ Relaunch as Root…*).

Release builds are signed with a Developer ID certificate, notarized, and use the hardened runtime,
which keeps other code from being injected into the running app (no `DYLD_INSERT_LIBRARIES`, no
unsigned libraries, no debugger attach).

## What this protects against

- **Other users of the Mac** can't connect to the helper or make it do anything.
- **Other processes of yours** can't connect to the helper either: it serves one process, the app.
- **JavaScript expressions** (filters, highlight rules, alerts) run in an embedded QuickJS-ng
  engine with no access to files, the network, timers or the app's objects, with a time limit and
  a memory limit.
- **Files you open in the inspector** (Mach-O files, crash reports) are treated as untrusted input.
- **A replaced helper.** A program running as you that swaps the helper in the bundle for its own
  doesn't get it run as root: the copy root makes fails the signature check, and nothing is
  started. The team is read from the kernel's record of the running app, not from the files on
  disk. Only root can read the copy, so a link swapped in for the helper doesn't hand over a file
  only root may read either. Once running, the helper only ever re-runs root's copy of itself.
- **Reports written as root.** Tools that write a report to a file (`sample`, `spindump`) write it
  into a new directory only root can open, and the text is passed back to the app, so there is no
  file in a shared place for another program to redirect.

## What it does not protect against

Be aware of these before you authorize the helper or run as root.

- **The helper does whatever the app asks.** Once authorized, the app can run any program as root
  through the helper (that is what *Run Program as Root* is). The helper's list of allowed tools
  limits which diagnostic tools it starts, but it is not a security boundary: several of those
  tools take arguments that write files or run commands.
- **A replaced app.** The check above protects the helper, on the word of the running app. It
  can't help if the whole application was replaced before you opened it: the password dialog you
  approve is then the replacement's. For the notarized release, macOS itself stops other apps from
  modifying the bundle (*App Management* in Privacy & Security); keep that protection on, and
  install Procopticon from the signed disk image.
- **Builds without a developer team.** A build you make yourself without a signing certificate
  (`swift build`, or `scripts/build-app.sh` with an ad-hoc signature) has no team to check the
  helper against. Root still runs only its own copy, but a helper swapped in the bundle before you
  authorize would be accepted. `swift build` output also has no hardened runtime.
- **Core dumps.** *Create Core Dump* runs `gcore` as root when the process isn't yours, writing to
  the place you choose. Choose a folder other programs can't prepare in advance.
- **Root mode runs the bundle as root.** `sudo …/Procopticon` and *Relaunch as Root* run the
  application itself as root, from wherever it is installed, with no signature check. A root
  instance also reads preferences and saved expressions that your account can write, and
  everything it starts runs as root unless Procopticon starts it as you (it does for Restart and
  for Run Program without *Run as root*). Prefer the helper.
- **Passwordless `sudo`.** If your account can `sudo` without a password, the helper starts with no
  dialog at all. Such an account is already equivalent to root.

In short: authorize the helper on a Mac you trust the other software on, and quit Procopticon (or
choose *Tools ▸ Stop Privileged Helper*) when you no longer need it elevated.

## What Procopticon reads and sends

- It makes no network connections of its own, with two exceptions you control: reverse DNS lookups
  of remote addresses while a network view is open, and *Search Online*, which opens your browser
  with the process's executable name in a search URL (DuckDuckGo unless you change it in Settings).
- It has no analytics, crash reporting or update checks.
- It reads, and never sends anywhere: the process list and what the system reports about each
  process (arguments and environment variables can contain secrets, and they are shown on screen and
  included in exports you make), the unified log, crash reports, launchd and startup configuration,
  and the LaunchServices quarantine database (to show where downloaded software came from).

## Private interfaces

Procopticon uses several undocumented macOS interfaces to show what Activity Monitor shows
(whether an app is responding, the responsible process, sandbox and code-signing state, memory
limits). They can change or stop working in any macOS release; the affected columns then go blank.
For the same reason Procopticon can't be distributed through the Mac App Store.
