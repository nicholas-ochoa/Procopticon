# Contributing to Procopticon

Bug reports, fixes and features are welcome. Procopticon is maintained by one person in spare time,
so small, focused changes are the ones most likely to be reviewed quickly.

## Before you start

- **Bugs:** open an issue with your macOS version, Mac model (Apple silicon or Intel), the mode
  Procopticon was in (Standard, Elevated helper or Root) and the steps that show the problem. For a
  crash, attach the report from *Tools ▸ Crash Reports…*.
- **Security problems:** don't open an issue. See [SECURITY.md](SECURITY.md).
- **Larger changes** (a new tab or tool, anything touching the privileged helper): open an issue
  first so the approach can be agreed on before you write it.
- **AI-assisted work** is welcome, with a human who understands it behind it. See
  [AI-POLICY.md](AI-POLICY.md).

## Building and testing

You need Xcode 26 or later on macOS 26 or later.

```sh
swift build                    # debug build of everything
swift test                     # unit tests
./scripts/build-app.sh         # build/Procopticon.app (ad-hoc signed without a Developer ID certificate)
VARIANT=dev ./scripts/build-app.sh   # "Procopticon Dev.app", with its own settings
```

`swift run Procopticon` works for most things. Notifications, the app icon and the About panel's
license texts need the bundle from `build-app.sh`. The reference lists
[launch arguments](docs/REFERENCE.md#launch-arguments) that open a particular window, which helps
when testing one.

Releases are built with `scripts/release.sh`, which needs the maintainer's Developer ID certificate.
The *Release* workflow (`.github/workflows/release.yml`) runs it on GitHub and publishes the disk
image. You don't need either to contribute.

## Where things go

`Package.swift` lists the targets. The rules that matter most:

- **`ProcopticonCore`** has the samplers, parsers and the privileged request protocol, and no UI.
  Anything that parses a tool's output or a file belongs here, as a function that takes text or
  data and can be tested without running the tool.
- **`procopticon-helper`** runs as root. It links `ProcopticonCore` only: no JavaScript engine and no
  UI code. Treat every new `PrivilegedRequest` as something an attacker could send, and keep what
  runs as root as small as you can.
- **`Sources/CQuickJS/quickjs`** is QuickJS-ng, unmodified. Don't edit it; update it by copying a
  newer release (see `quickjs/VERSION`).
- No new dependencies without discussion. The project builds with the Swift Package Manager alone.

## Code

- Match the code around you. Swift 5 language mode; lines up to about 130 columns.
- Sampling, parsing and sorting stay off the main thread; the main thread swaps in finished
  snapshots.
- Data read from other processes, files and tool output is untrusted: check bounds, use wrapping
  or clamping arithmetic on values you didn't compute, and never force-unwrap it.
- Comments say why, not what. Document the macOS behavior a workaround exists for.
- Fixes and parsers come with a unit test in `Tests/ProcopticonCoreTests`.
- User-facing text follows the Mac's conventions (title-case menu items, sentence-case labels,
  `▸` for menu paths), and every control has a tooltip.
- Update `docs/REFERENCE.md` when you add or change something a user can see, and the README when
  its summary no longer fits.

## Commits and pull requests

- One change per commit. The subject says where and what, in the style of the history:
  `Process list: Focus on a process`, `Settings ▸ Alerts: notify when processes meet a rule`.
  The body explains what was wrong or missing and what changed, in plain sentences.
- A pull request describes what it changes, how you tested it and on which macOS version. Say so if
  you couldn't test something (the elevated helper, an Intel Mac).
- `swift build` and `swift test` must pass.

## License

Procopticon is released under the [MIT License](LICENSE). By contributing, you agree that your
contribution is released under the same license, and you confirm that you have the right to
submit it.
