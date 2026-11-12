# Procopticon

Procopticon is a native process explorer for macOS, built with Swift and SwiftUI.

![Procopticon process tree](docs/screenshots/processes.png)

## Why?

On Windows I used [Sysinternals Process Explorer](https://learn.microsoft.com/en-us/sysinternals/downloads/process-explorer) for years, and then [System Informer](https://github.com/winsiderss/systeminformer/) (formerly Process Hacker), which I still use on every Windows machine I work on. Activity Monitor on macOS isn't bad, but it has never had the power-user features I got used to in those tools. Procopticon is my attempt at a process manager for the Mac that does everything I could need or want from one.

## How?

Nearly all of Procopticon was written with AI. If that's something you'd rather avoid, this project probably isn't for you. [AI-POLICY.md](AI-POLICY.md) covers how AI is used here and what's expected of AI-assisted contributions.

## What it does

- **Process monitoring:** A live process tree with roughly 95 available columns for CPU, memory, disk, network, GPU, power, scheduling, and more. Helper processes are grouped under the applications responsible for them.
- **Search and filters:** Find processes by name, PID, user, path, or command line. Use regex or JavaScript expressions, save filters, and configure highlighting and alerts.
- **Process inspection:** Examine threads, open files, sockets, loaded modules, memory regions, environment variables, logs, crash reports, and code-signing details.
- **Process controls:** Terminate, suspend, resume, restart, send signals, or run tools like `sample`, `spindump`, `vmmap`, `lsof`, and `fs_usage`.
- **Services and startup items:** Inspect and manage launchd jobs, login items, extensions, cron jobs, and other startup mechanisms.
- **System monitoring:** Per-core CPU graphs, memory pressure, disk and network activity, GPU usage, power, and thermal information.
- **Privacy and security:** See which processes use the microphone, camera, or screen recording, and inspect signatures, entitlements, sandboxing, and quarantine information.

![Process properties](docs/screenshots/process-properties.png)

For details on individual views, filters, expressions, privileges, and tools, see the [feature reference](docs/REFERENCE.md).

## Installing

Requires **macOS 26+**. With [Homebrew](https://brew.sh):

```sh
brew install --cask nicholas-ochoa/tap/procopticon
```

Or download the disk image from the [latest release](https://github.com/nicholas-ochoa/Procopticon/releases/latest).

## Building

Requires **macOS 26+** and **Xcode 26+**.

```sh
./scripts/build-app.sh       # Build build/Procopticon.app
./scripts/install.sh         # Build, install to /Applications, and open
swift test                   # Run unit tests
```

For a development build that can run alongside the installed app:

```sh
VARIANT=dev ./scripts/build-app.sh
```

To create a signed, notarized release DMG:

```sh
VERSION=1.0.0 ./scripts/release.sh
```

See the release script for setup instructions. More build options and launch arguments are in the [reference](docs/REFERENCE.md#building).

## Privileges

Procopticon works without elevated privileges, but macOS restricts what it can read or change in processes belonging to other users. You can authorize its privileged helper when needed, or authorize on startup.

See [Privileges](docs/REFERENCE.md#privileges) and [SECURITY.md](SECURITY.md) for the details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), [AI-POLICY.md](AI-POLICY.md), and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Procopticon includes [QuickJS-ng](https://github.com/quickjs-ng/quickjs), also MIT licensed. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
