# Procopticon

A native macOS process explorer built around macOS and Unix concepts:
launchd, Mach-O, code signing, sandboxing, Rosetta, BSD signals and `nice` priorities.

Written in Swift and SwiftUI. A small C layer wraps `libproc`, `sysctl`, Mach host statistics and
IOKit. Large lists use AppKit `NSOutlineView` so that thousands of rows can refresh every second.

## Features

**Processes** — a live process tree with icons and about 70 optional columns (right-click the header).
Applications appear under their app name (Parallels Desktop rather than `prl_client_app`).
Columns cover CPU (user/kernel), physical footprint, peak memory, resident and virtual size, disk
read/write rates, GPU usage and GPU time, threads, open files, cycles, instructions and IPC, context switches, system calls,
wake-ups, energy and power, nice/priority, start time, command line, bundle identifier/version,
architecture (arm64 or Rosetta), sandbox, code-signing verification and signer, and team ID. There are
also CPU, memory, disk and GPU history graph columns. The **Process title** column shows the title a process
gave itself by overwriting its first argument (Node's `process.title`, `setproctitle`, "postgres:
checkpointer"); it stays empty for processes started under their own name, a symlink or shim. Hover over a
cut-off value to see all of it.

* Row highlighting: new/terminated, stopped, zombie, traced, Rosetta,
  elevated (setuid/sudo), unsigned, sandboxed, applications, own, root and service-account
  processes. Colors and priorities are configurable.
* Search by name, PID, path, command line, user or bundle ID. Every search and filter field accepts
  **regular expressions**. Click `.*` at the right end of the search field or use *View ▸ Use Regular
  Expressions in Search* (⌥⌘R), or write `/pattern/` at any time. Patterns are case-insensitive;
  `/pattern/c` makes one case-sensitive. An invalid pattern is reported in the status bar.
* **Quick filters** in the toolbar: **Apps** (GUI applications and the processes they started), **Mine** (your processes only),
  **Tree/List**, and a **Filters** menu (hide root/system, Apple-signed or zombie processes). While a
  filter is active, the status bar shows "Showing N of M" with a **Clear Filters** link.
* **Saved filters** store a search plus filter settings under a name. Apply one from the Filters menu or
  from *View ▸ Saved Filters* (⌃⌘1–9). Manage them in *Settings ▸ Filters*: create one from the current
  state, edit, duplicate, reorder or delete.
* **Customizable toolbar**: *View ▸ Customize Toolbar…*. By default the buttons are right-aligned and
  arranged in groups: Quick Filters, Updates, Tools, and Privileges & Settings. More groups are available
  in the palette: Process Actions, Inspection Windows, Files & Programs. So is every individual button,
  plus Space, Flexible Space and the search field.
* An optional **fixed-width font** (and font size) for the process list, set in *Settings ▸ General*.
  You can also hide other users' processes, system processes, Apple-signed processes or zombies, or
  switch to a flat list.
* Actions:
  * Terminate, Terminate Tree, Force Kill, Suspend/Resume (also for a whole tree), Restart.
  * Send any signal, set the `nice` value, or switch background (throttled) scheduling.
  * Bring an app to the front or quit it gracefully.
  * Reveal in Finder, inspect the executable, search online, copy values, go to the parent or the
    responsible process.
* Diagnostics: `sample`, `spindump`, `vmmap`, `footprint`, `heap`, `leaks`, `lsof` and core dumps.
  When needed, these run elevated automatically.

**Process properties** open in a window with these sections in a sidebar. The window resizes to fit
each section as you switch:

| Tab | Contents |
| --- | --- |
| General | Image, command line, process title, working directory, parent and responsible process, user, code signature |
| Statistics | CPU, memory, I/O, Mach message, system call and energy counters |
| Performance | CPU, memory and disk graphs |
| Threads | Live thread list; double-click a thread to capture its stack |
| Modules | Loaded images, including the dyld shared cache |
| Memory | VM regions with type, protection, share mode, and resident, dirty and swapped sizes |
| Arguments | The command line, one argument per row. For a process that replaced them with a title, the arguments as launched when Procopticon saw it start |
| Environment | Environment variables |
| Files | Open file descriptors: files, sockets, pipes, kqueues and shared memory |
| Network | The process's sockets |
| Security | Credentials and groups, signing details, certificate chain and entitlements |
| Service | The launchd job that owns the process |

**Services** list every launchd job in the system domain and in your GUI domain. That includes daemons,
agents, login items and XPC services, whether or not they are loaded, along with their PID, status, last
exit code, start conditions and enabled state. You can Start, Stop, Restart, Load (bootstrap), Unload
(bootout), Enable or Disable a job, view its live `launchctl print` state, or view its property list.

**Network** shows all TCP and UDP endpoints with the owning process, reverse-DNS host names and
well-known service names. New and closed connections are highlighted.

**Disk** shows per-process disk throughput and totals, with history graphs.

**System Information** has these sections:

* CPU: total plus one graph per core, labeled P or E. Hovering a point shows the busiest process at
  that moment.
* Memory: app, wired, compressed, cached and free memory, plus pressure, swap, page-in/out and
  compression rates.
* Disk: throughput and capacity of each volume.
* Network: throughput of each interface.
* GPU: utilization, core count and memory use, and the processes using the GPU.
* Power: battery state and estimated process power.

**Tools**:

* **Find Files or Libraries.** Searches the open files and mapped images of every process (`lsof`-like).
* **Inspect Executable.** A Mach-O viewer showing the header and architecture slices, load commands,
  segments and sections, linked libraries, symbols, code signature, entitlements and the embedded
  Info.plist.
* **Find Process by Window.**
* **Hidden Process Scan.** Compares the kernel process list against a brute-force probe of every PID.
* **Logged-in Users.**
* **Event Log.** Records process start/exit, service start/stop and actions you take.
* **Run Program** and **Run Program as Root.**
* **Purge Disk Cache** and **Flush DNS Cache.**
* **Export.** Saves the process list as text.

A **menu bar graph** (CPU, memory, network or disk) opens a popover showing the top processes.

## Responsiveness

Sampling, delta computation, filtering and tree building run on a background queue. Each update
publishes immutable snapshots, so the main thread only swaps them in. Tables sort on a background queue
and update incrementally: flat lists rebind row slots, and trees apply moves, inserts and removes instead
of reloading. Tied rows sort stably so they don't jitter. Icons, bundle metadata and code-signing checks
load asynchronously.

Memory-region scans of other processes (the Memory and Modules tabs, and library search in Find Files)
run in a disposable child process. On recent macOS releases the kernel can kill the *caller* of that
query with `EXC_GUARD` for some targets.

## Privileges

macOS only lets an unprivileged process fully inspect processes that run as the same user. Procopticon
runs in one of three modes. The current mode appears at the right end of the status bar.

| Mode | How | Behaviour |
| --- | --- | --- |
| **Standard** | Normal launch | You see your own processes in full and other processes in outline. If an action is denied, you are asked for an administrator password once, which starts the helper (below). |
| **Elevated helper** | Toolbar 🔒 button, *File ▸ Show Details for All Processes*, or *Settings ▸ Privileges ▸ Authorize at launch* | `procopticon-helper` is started as root through the standard macOS authorization dialog. If `sudo` needs no password, it is started with `sudo -n` and no dialog appears. The helper listens on a `0600` Unix socket in your per-user temporary directory and serves exactly one client: every connection is checked against the app's PID and UID. Tools it may run are allowlisted. It exits when the app quits. |
| **Root ("sudo mode")** | `sudo "/Applications/Procopticon.app/Contents/MacOS/Procopticon"` or *File ▸ Relaunch as Root…* | The whole app runs as root. Everything executes in-process and **you are never prompted**. Your own processes are still recognized through `SUDO_UID`. |

System Integrity Protection still applies in every mode. Apple platform binaries cannot be attached to,
but `sample`, `vmmap` and libproc data remain available for them when you run as root.

## Building

You need Xcode 26 or later and macOS 26 or later (the project was developed with Xcode 27 on macOS 27).

```sh
./scripts/build-app.sh               # release build → build/Procopticon.app (ad-hoc signed)
SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh   # sign with a certificate
swift test                           # unit tests for the samplers and parsers
```

You can also use `swift build` and `swift run Procopticon` while developing.
`VARIANT=dev ./scripts/build-app.sh` builds **Procopticon Dev.app**. It has its own bundle
identifier, executable name and preferences, so it can run next to the installed app without
sharing settings or window positions.

Launch arguments are useful for scripting and testing:

```text
--elevate                    authorize at startup
--search <text>              pre-fill the process search (e.g. '/^mdworker/')
--tab processes|services|network|disk
--show-properties <pid>      [--properties-tab General|Threads|Modules|Memory|Files|…]
--show-sysinfo summary|cpu|memory|disk|network|gpu|power
--show-find <text>    --inspect <path>    --show-service <label>    --show-log    --show-windows
```

## Layout

```text
Sources/CSysInfo            C: libproc/sysctl/Mach/IOKit wrappers (processes, FDs, sockets, threads, VM regions, host stats)
Sources/ProcopticonCore     Swift: samplers, process/network stores, launchd services, code signing, Mach-O parser,
                            privileged request protocol, executor, helper transport, elevation broker
Sources/procopticon-helper  Root helper executable
Sources/Procopticon         SwiftUI/AppKit app
Tests/ProcopticonCoreTests  Unit tests
Resources/AppIcon.png       App icon artwork: a full-bleed square. scripts/make-icon.swift adds the macOS icon shape,
                            rim light and shadow, and renders every size.
```
