# Procopticon

A native macOS process explorer built around macOS and Unix concepts:
launchd, Mach-O, code signing, sandboxing, Rosetta, BSD signals and `nice` priorities.

Written in Swift and SwiftUI. A small C layer wraps `libproc`, `sysctl`, Mach host statistics and
IOKit. Large lists use AppKit `NSOutlineView` so that thousands of rows can refresh every second.

## Features

**Processes** — a live process tree with icons and about 70 optional columns (right-click the header).
Applications appear under their app name (Parallels Desktop rather than `prl_client_app`). As in
Activity Monitor, processes launchd started on an app's behalf (XPC services, daemonized helpers)
are listed under the app responsible for them.
Columns cover CPU (user/kernel), physical footprint, peak memory, compressed and purgeable memory,
resident and virtual size, the jetsam priority band and memory limit, Mach ports, disk
read/write rates, GPU usage and GPU time, network send/receive rates (separately, or together with ↓/↑ arrows in
**Network rate**) and bytes/packets sent and received (from `nettop`), threads, open files, cycles, instructions and IPC, context switches, system calls,
wake-ups, energy and power, power assertions and **Preventing Sleep** (whether the process keeps the Mac or
its display awake), nice/priority, start time, command line, bundle identifier/version,
architecture (arm64 or Rosetta), sandbox, code-signing verification and signer, team ID, and the
**Download source** of quarantined software. There are
also CPU, memory, disk, GPU and network history graph columns. The **Process title** column shows the title a process
gave itself by overwriting its first argument (Node's `process.title`, `setproctitle`, "postgres:
checkpointer"); it stays empty for processes started under their own name, a symlink or shim. Hover over a
cut-off value to see all of it.

* **Microphone, Camera** and **Screen recording** columns show which processes are using them, and such
  processes are highlighted. The microphone comes from Core Audio, per process. macOS has no API that
  says which app uses the camera or records the screen, so those come from the attributions Control
  Center logs for its privacy indicators (followed with `log stream`, which needs an administrator
  account). The Event Log records each start and stop.
* Row highlighting: new/terminated, not responding, recording (microphone, camera, screen), stopped, zombie, traced,
  Rosetta, elevated (setuid/sudo), unsigned, sandboxed, applications, own, root and service-account
  processes. Colors and priorities are configurable. Add your own rules in *Settings ▸ Highlighting*: each
  is a [filter](#filters) and a color, such as the JavaScript expression `memory > 2 * GB` in red.
* **Hung applications**: an application that has stopped responding to events (the spinning wait
  cursor) reads "(Not Responding)" after its name, as in Activity Monitor, and is highlighted. The
  **Responding** column says how long it has been hung, *Filters ▸ Only Applications Not Responding*
  lists just those, and the Event Log records when an app stops and starts responding again.
* Search by name, PID, path, command line, user or bundle ID. Every search and filter field accepts
  **regular expressions**. Click `.*` at the right end of the search field or use *View ▸ Use Regular
  Expressions in Search* (⌥⌘R), or write `/pattern/` at any time. Patterns are case-insensitive;
  `/pattern/c` makes one case-sensitive. An invalid pattern is reported in the status bar.
* Search the process list with a **[JavaScript expression](#expressions)**: click `{}` in the search
  field or use *View ▸ Use JavaScript in Process Search* (⌥⌘J), then type `cpu > 10 && user == "root"`
  or `memory > 1 * GB && !appleSigned`.
* **Quick filters** in the toolbar: **Apps** (GUI applications and the processes they started), **Mine** (your processes only),
  **Tree/List**, and a **Filters** menu (hide root/system, Apple-signed or zombie processes, or show only
  applications that aren't responding). While a
  filter is active, the status bar shows "Showing N of M" with a **Clear Filters** link.
* **Focus**: right-click a process and choose *Focus* to list only it and its descendants, with the
  process at the top of the tree. The search and other filters still apply within it. Choose *Focus*
  again, *Filters ▸ Stop Focusing*, or **Clear Filters** to show every process again; focus also ends
  once the process has exited and left the list.
* **Summary panel**: click the CPU, Memory, Disk, Network or GPU stats in the status bar to open an
  Activity Monitor–style panel above it: totals and rates beside a history graph (CPU load, memory
  pressure, disk IO or data, network packets or data, GPU). Click again to close it.
* **Alerts** (*Settings ▸ Alerts*): rules that post a notification when a process goes over a CPU,
  memory, disk, network or GPU threshold for a given time, starts, exits, stops responding, keeps
  the Mac awake, uses the microphone, camera or screen recording, or matches a [filter](#filters) of
  your own (such as the JavaScript expression `cpu > 50 && memory > 2 * GB`). A rule can watch every
  process or those matching its filter. Clicking a notification selects the process, and every alert is
  recorded in the Event Log.
* **Saved filters** store a search plus filter settings under a name. Apply one from the Filters menu or
  from *View ▸ Saved Filters* (⌃⌘1–9). Manage them in *Settings ▸ Filters*: create one from the current
  state, edit, duplicate, reorder or delete.
* **Customizable toolbar**: *View ▸ Customize Toolbar…*. By default the buttons are right-aligned and
  arranged in groups: Quick Filters, Updates, Tools, and Privileges. More groups are available
  in the palette: Process Actions, Inspection Windows, Files & Programs. So is every individual button
  (Refresh and Settings among them), plus Space, Flexible Space and the search field.
* An optional **fixed-width font** (and font size) for the process list, set in *Settings ▸ Appearance*.
* **Appearance**: System (follows macOS), Light or Dark, in *Settings ▸ Appearance* or *View ▸ Appearance*.
  You can also hide other users' processes, system processes, Apple-signed processes or zombies, or
  switch to a flat list.
* Actions:
  * Terminate, Terminate Tree, Force Kill, Suspend/Resume (also for a whole tree), Restart.
  * Send any signal, set the `nice` value, or switch background (throttled) scheduling.
  * Each of these checks the process's start time just before it acts: if the process has exited and
    its PID now belongs to another process (a confirmation or password prompt can stay open a while),
    that process is left alone and the action reports that the process has exited.
  * Bring an app to the front or quit it gracefully.
  * Reveal in Finder, inspect the executable, search online, copy values, go to the parent or the
    responsible process.
* Diagnostics: `sample`, `spindump`, `vmmap`, `footprint`, `heap`, `leaks`, `lsof`, live file activity (`fs_usage`) and core dumps.
  When needed, these run elevated automatically.

**Process properties** open in a window with these sections in a sidebar. The window resizes to fit
each section as you switch:

| Tab | Contents |
| --- | --- |
| General | Image, command line, process title, working directory, parent and responsible process, user, code signature, and for downloaded software its quarantine flag: which app downloaded it and when, whether you approved opening it, and the download URL and page when recorded |
| Statistics | CPU, memory, I/O, Mach message, system call and energy counters |
| Performance | CPU, memory and disk graphs |
| Power | Power assertions the process holds, or another holds for it (e.g. coreaudiod while it plays sound): type, name, how long, timeout and details |
| Threads | Live thread list; double-click a thread to capture its stack |
| Modules | Loaded images, including the dyld shared cache |
| Memory | VM regions with type, protection, share mode, and resident, dirty and swapped sizes |
| Arguments | The command line, one argument per row. For a process that replaced them with a title, the arguments as launched when Procopticon saw it start |
| Environment | Environment variables |
| Files | Open file descriptors: files, sockets, pipes, kqueues and shared memory |
| File Activity | The files the process opens, reads, writes and looks up, live (`fs_usage`, as root): each call with its file (named from the descriptor when the call doesn't say), bytes, duration and error, or summed up by file. Also in the process menu under Diagnostics |
| Network | The process's sockets |
| Crash Reports | macOS's crash, exception, hang, resource (CPU, disk writes, wake-ups) and jetsam reports for the executable; double-click one to read it |
| Log | The process's messages in the unified log, live (`log stream`) after those from the last five minutes, with a Default/Info/Debug level, pause, filter and earlier history (`log show`). Errors and faults are highlighted |
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

* Summary: the Mac's model name ("MacBook Pro (16-inch, Nov 2023)") and identifier, macOS, processor,
  memory and uptime.
* CPU: total plus one graph per core, labeled P or E from each core's type in the IORegistry. Hovering
  a point shows the busiest process at that moment. When elevated, each cluster's current frequency
  too. The processor's core types with their L1 and L2 caches, and the cache line size.
* Memory: app, wired, compressed, cached and free memory, plus pressure, swap, page-in/out and
  compression rates, and the memory installed and usable by macOS.
* Disk: throughput and capacity of each volume, its format, and whether it's internal, external,
  removable or on the network, encrypted or read-only.
* Network: throughput of each interface, and each one's IP addresses, hardware address, MTU and link
  speed.
* GPU: utilization, core count and memory use, and the processes using the GPU. From Metal: unified or
  dedicated memory, recommended working set, largest buffer, Metal support (Apple GPU family, Metal 3
  or 4), hardware ray tracing and threadgroup limits.
* Power: battery state, estimated process power, power measured by `powermetrics` when elevated, and
  the processes keeping the Mac or its display awake.
* Thermal: the thermal state macOS reports (Nominal, Fair, Serious, Critical) with its history and,
  from `powermetrics` (as root, while the section is open), thermal pressure, each CPU cluster's
  frequency and activity, the GPU's frequency, and CPU, GPU and Neural Engine power.

**Resource History** (*View ▸ Resource History*, ⌥⌘G, or the Tools toolbar group) is a floating,
resizable window of Activity Monitor–style history graphs in one place: one graph per CPU core (user time
in green over system time in red), the GPU, and memory (wired, compressed and app memory), with optional
total CPU, network and disk graphs. Choose the graphs from the ⋯ button in its title bar or by
right-clicking. The graphs rearrange into columns as you resize the window. It stays above other windows
unless you turn off *Always on Top* in the same menu, and reopens at launch if it was open when you quit.

**Tools**:

* **Find Files or Libraries.** Searches the open files and mapped images of every process (`lsof`-like).
* **Inspect Executable.** A Mach-O viewer showing the header and architecture slices, load commands,
  segments and sections, linked libraries, symbols, strings, code signature, quarantine, entitlements
  and the embedded Info.plist. **Strings** lists the text in each section with its address: C-string
  sections (`__cstring`, `__objc_methname`, `__oslogstring`…) split at their terminators as UTF-8,
  `__ustring` as UTF-16, and printable ASCII runs elsewhere, as `strings(1)` finds them. Code, stubs,
  pointer tables and `__LINKEDIT` (whose symbols the Symbols page lists) are skipped. Show one
  section, set a minimum length, filter, and copy.
* **Find Process by Window.**
* **Crash Reports.** Every crash, exception, hang, resource and jetsam report in the user and system
  DiagnosticReports folders (including Retired ones), grouped by process so the apps that keep crashing
  stand out. JSON crash reports open laid out like classic crash logs: exception, termination reason,
  every thread's backtrace with the crashed one first, and the binary images. Open in Console or reveal
  any report from its menu.
* **Startup Items.** An Autoruns- or KnockKnock-style tree of what starts code outside launchd's job
  list (which the Services tab covers): Open at Login apps, login items and background items from Background Task
  Management (`sfltool dumpbtm`, with their app, developer, and whether they're allowed in Login Items
  settings), Quick Look, Spotlight and Dock tile extensions, system and kernel extensions, cron jobs,
  periodic scripts, login and logout hooks, authorization plug-ins, plug-ins that load into other
  processes (input methods, screen savers, audio and camera drivers…), configuration profiles and
  legacy startup items. Apple's own are hidden unless you ask. Every user's cron jobs and the login
  hooks need the elevated helper.

  Right-click items to **Disable**, **Enable** or **Remove…** them (⌫ removes too):

  | Item | Disable / Enable | Remove |
  | --- | --- | --- |
  | Open at Login apps | Taken off the list and remembered here, so they stay listed / put back | Taken off the list |
  | Login and background items (agents, daemons) | `launchctl disable` / `enable` on the job | Ones with their own property list: unloaded, and the list moved to the Trash. Items an app registered itself are removed by the app |
  | Quick Look and Spotlight extensions | `pluginkit -e ignore` / `use`, for you | — |
  | Cron jobs | Commented out with a marker / restored | The line is deleted |
  | Periodic scripts | Execute permission off / on | Moved to the Trash |
  | Login and logout hooks | — | The setting is deleted (the script stays) |
  | Plug-ins, legacy startup items | — | Moved to the Trash |
  | Configuration profiles | — | `profiles remove` |

  Disabling doesn't stop what's already running; it keeps the item from starting again. Changes to your
  own items run as you; the rest go through the helper, which only changes files in the startup and
  plug-in folders. Authorization plug-ins, system and kernel extensions are listed but left alone:
  removing an authorization plug-in the system still uses can stop anyone from logging in.
* **Logged-in Users.**
* **Event Log.** Records process start/exit, service start/stop, apps that stop or start responding,
  processes that start or stop keeping the Mac awake, alerts, and actions you take.
* **Run Program** and **Run Program as Root.**
* **Open at login**: *Settings ▸ General ▸ Open Procopticon at login* adds the app to *System Settings ▸
  General ▸ Login Items* (useful with the menu bar graph). If macOS asks for approval, a button opens
  those settings.
* **Purge Disk Cache** and **Flush DNS Cache.**
* **Export** (*File ▸ Export Process List…*, ⌘S). Saves the process list as shown (its visible columns
  and rows, filtered and sorted) as JSON, the default, or CSV, chosen in the save panel. Values are
  raw rather than formatted: bytes, bytes per second, percentages, seconds and ISO 8601 dates, with
  the units in the JSON's `units` object and in the CSV's column headers. Values that couldn't be read
  are null (empty in CSV).

A **menu bar graph** (CPU, memory, network or disk) opens a popover showing the top processes.

## Filters

Saved filters, custom highlight rules and alerts (*Settings ▸ Filters*, *Highlighting* and *Alerts*) each
have a filter with three tabs:

* **Text** matches anywhere in the name, path, command line, title, user, app name or bundle ID, ignoring
  case, or the PID exactly. `/pattern/` is a regular expression here too.
* **Regex** is a regular expression (ICU syntax, case-insensitive; `(?-i)` makes the rest case-sensitive).
* **JavaScript** is an [expression](#expressions) over the process's values.

The editor is fixed-width and colors the syntax of regular expressions and JavaScript, including the
pattern inside a JavaScript regex literal (`/helper/i.test(name)`). A parenthesis that closes nothing or is
never closed, a quantifier with nothing to repeat and an unfinished character class are marked in red.
Under the editor, the filter's error or how many running processes it matches updates as you type. The
search field has the same three modes: plain text, `.*` and `{}`.

In JavaScript, here and in the search field's `{}` mode, a list of completions follows the word you type: the process's values, `KB`…`TB`, a few
keywords, `Math` and `Date`, and after a dot the methods of what's before it when its type is known
(`name.` lists string methods, `args.` array ones, `/re/.` `test` and `exec`). ↑ and ↓ choose, Tab or
Return accepts, Esc closes the list. With no list showing, ⌃Space (or Esc, in Settings; in the search
field Esc clears the search) opens it with everything that fits, even before you've typed anything. (If ⌃Space switches input sources in *System Settings ▸
Keyboard ▸ Keyboard Shortcuts ▸ Input Sources*, macOS takes it first; Esc still works.) Tab on a partial
word completes it at once when only one thing fits.

Settings saved by earlier versions, where an expression was written `=expression`, are converted.

## Expressions

JavaScript filters are evaluated for each process. The process's values are variables, so
`cpu > 50 && /helper/i.test(name)` matches busy helpers. *View ▸ Expression Reference* lists them all,
and the ? button above a JavaScript filter shows the same list.

| | Values |
| --- | --- |
| Identity | `pid` `ppid` `pgid` `responsiblePid` `name` `executable` `path` `commandLine` `args` (array) `title` `description` `user` `uid` `realUser` `group` `bundleId` `version` `company` `teamId` `arch` `tty` `state` |
| Resource use | `cpu` `cpuUser` `cpuKernel` (percent, as shown) `cpuTime` (seconds) `memory` `peakMemory` `resident` `virtualSize` `wired` `compressed` `purgeable` `memoryLimit` (bytes) `jetsamPriority` `gpu` `diskRate` `diskReadRate` `diskWriteRate` `netRate` `netInRate` `netOutRate` (bytes/s) `diskRead` `diskWrite` `netIn` `netOut` (bytes) `threads` `runningThreads` `fds` `ports` `priority` `nice` `power` (W) `age` (seconds) `startTime` (Date) |
| State (true/false) | `app` `mine` `exited` `notResponding` `preventingSleep` `microphone` `camera` `screenRecording` `stopped` `zombie` `traced` `translated` `elevated` `sandboxed` `signed` `appleSigned` `platformBinary` `hardenedRuntime` `quarantined` |

`KB`, `MB`, `GB` and `TB` are byte units (1 KB = 1024 bytes). Text that isn't known is empty; numbers and
true/false values that aren't known are `null`. Errors are reported in the status bar, or under the rule in
Settings. Error positions refer to your expression, so `cpu > 5)` reports the extra `)` at column 8.

Expressions run in [QuickJS-ng](https://github.com/quickjs-ng/quickjs) (MIT; `Sources/CQuickJS/quickjs`,
unmodified), not in the system's JavaScriptCore. QuickJS can stop a script that runs too long and cap its
memory. JavaScriptCore has no public API for either, and a saved highlight rule with an endless loop
would hang the app every time it launched. Each engine (the process store, the alerts and Settings have
one each) is a separate context with no access to files, the network or timers, limited to 32 MB. An
expression that runs for more than 250 ms is stopped and not run again until it changes. Fields are read
only when an expression uses them. Over 800 processes, `cpu > 5` takes about 0.1 ms and an expression
testing names, users and paths under 1 ms, on the background queue that builds each update.

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
| **Elevated helper** | Toolbar shield button, *File ▸ Show Details for All Processes*, or *Settings ▸ Privileges ▸ Authorize at launch* | `procopticon-helper` is started as root through the standard macOS authorization dialog. If `sudo` needs no password, it is started with `sudo -n` and no dialog appears. Root runs a copy of the helper that it has placed where only root can change it, after checking that the copy is signed by the same developer as the app. The helper listens on a `0600` Unix socket in `/var/run/procopticon`, which only root can write to, and serves exactly one client: every connection is checked against the app's PID and UID. It does what the app asks of it, including running programs as root, so see [SECURITY.md](SECURITY.md) for what that does and doesn't protect against. It exits when the app quits. |
| **Root ("sudo mode")** | `sudo "/Applications/Procopticon.app/Contents/MacOS/Procopticon"` or *File ▸ Relaunch as Root…* | The whole app runs as root. Everything executes in-process and **you are never prompted**. Your own processes are still recognized through `SUDO_UID`. |

System Integrity Protection still applies in every mode. Apple platform binaries cannot be attached to,
but `sample`, `vmmap` and libproc data remain available for them when you run as root.

## Building

You need Xcode 26 or later and macOS 26 or later (the project was developed with Xcode 27 on macOS 27).

```sh
./scripts/build-app.sh               # release build → build/Procopticon.app, signed with your
                                     # Developer ID certificate if you have one, otherwise ad-hoc
SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh   # sign with another certificate (- for ad-hoc)
swift test                           # unit tests for the samplers and parsers
VERSION=1.0.0 ./scripts/release.sh   # universal, Developer ID-signed and notarized → build/Procopticon-1.0.0.dmg
```

`release.sh` is for the copy handed to other people. It needs a Developer ID Application certificate
and notarization credentials in the keychain; the top of the script says how to set them up.

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
--show-sysinfo summary|cpu|memory|disk|network|gpu|power|thermal
--show-find <text>    --inspect <path>    --show-service <label>    --show-log    --show-windows    --show-crashes    --show-startup
```

## Layout

```text
Sources/CSysInfo            C: libproc/sysctl/Mach/IOKit wrappers (processes, FDs, sockets, threads, VM regions, host stats)
Sources/CQuickJS            C: QuickJS-ng (quickjs/, vendored unmodified; see quickjs/VERSION) and a small bridge for
                            evaluating expressions over rows of fields
Sources/ProcopticonExpressions  Swift: the expression engine and the process fields expressions use. Kept out of
                            ProcopticonCore so the root helper carries no JavaScript engine
Sources/ProcopticonCore     Swift: samplers, process/network stores, launchd services, code signing, Mach-O parser,
                            privileged request protocol, executor, helper transport, elevation broker
Sources/procopticon-helper  Root helper executable
Sources/Procopticon         SwiftUI/AppKit app
Tests/ProcopticonCoreTests  Unit tests
Resources/AppIcon.icon      App icon (Icon Composer; open it there to edit). macOS draws the shape, shadow and the
                            Dark, Clear and Tinted styles; build-app.sh compiles it with actool.
Resources/AppIcon-artwork.png  The flat artwork. scripts/split-icon.py splits it into the icon's layers (waveform,
                            blips, bezel, sweep, screen) and regenerates AppIcon.icon.
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for building, testing and what a change should look like,
[AI-POLICY.md](AI-POLICY.md) for AI-assisted contributions, and [SECURITY.md](SECURITY.md) for
reporting a vulnerability and for what the elevated helper does and doesn't protect against.

## License

Procopticon is released under the [MIT License](LICENSE). It includes
[QuickJS-ng](https://github.com/quickjs-ng/quickjs), also MIT licensed; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Both licenses are shown in *Procopticon ▸ About
Procopticon*.

Procopticon uses undocumented macOS interfaces for some of what it shows, so it isn't, and can't be,
distributed through the Mac App Store.
