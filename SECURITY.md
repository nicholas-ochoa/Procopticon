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
  It listens on a Unix socket in `/var/run/procopticon`, a directory only root can write to. The
  socket is owned by you with mode `0600`, and the helper accepts a connection only when the peer
  is the app process that started it (checked by PID and UID before any request is read).
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

## What it does not protect against

Be aware of these before you authorize the helper or run as root.

- **The helper does whatever the app asks.** Once authorized, the app can run any program as root
  through the helper (that is what *Run Program as Root* is). The helper's list of allowed tools
  limits which diagnostic tools it starts, but it is not a security boundary: several of those
  tools take arguments that write files or run commands.
- **Software already running as you can become root through Procopticon.** The app and the helper
  are files in an application bundle that your account can usually modify (anything in
  `/Applications` that you installed by dragging). A malicious program running as you could replace
  them and wait for you to approve Procopticon's password dialog, or, while the helper is running,
  replace the helper's file, which the helper runs again as root for memory-region scans. The
  helper does not verify the code signature of the app or of itself. macOS has the same limitation
  for any tool that elevates from a user-writable location; a helper installed in a root-owned
  location and checked by signature would close it and is planned.
- **Reports written as root.** Some diagnostics (`sample`, `spindump`) are run as root with an
  output file in your temporary directory. A malicious program running as you could plant a link
  there to make root overwrite another file.
- **Root mode trusts your settings.** A root instance reads preferences and saved expressions that
  your account can write, and everything it starts runs as root unless Procopticon starts it as you
  (it does for Restart and for Run Program without *Run as root*).
- **Passwordless `sudo`.** If your account can `sudo` without a password, the helper starts with no
  dialog at all. Such an account is already equivalent to root.
- **Builds you make yourself** with `swift build` or `scripts/build-app.sh` are ad-hoc signed.
  `swift build` output has no hardened runtime.

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
