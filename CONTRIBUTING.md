# Contributing to Runout Bar

Bug reports, fixes and features are welcome. For anything larger than a fix, open an issue first
so the approach can be agreed before you write the code.

## Set up

You need macOS 15 or later and a Swift 6 toolchain (Xcode or the Command Line Tools). The package
has no dependencies.

```bash
git clone https://github.com/RobinVivant/runout-bar.git
cd runout-bar
swift build
swift test
```

You do not need TeamClaude, Codex, Google AI or any account to work on the app. Demo mode runs it
on made-up accounts, and every action in it changes nothing:

```bash
swift run RunoutBar --demo
```

## Check your change

| Command | What it checks |
|---------|----------------|
| `swift test` | Parsing, pace, run-out, chart readouts, resets, the API queue, history, alerts and updates |
| `swift run RunoutBar --demo` | The real menu bar item and popover, on made-up data |
| `swift run RunoutBar --snapshot /tmp/runout-bar --demo` | Every screen in dark and light, as PNG files |
| `swift run RunoutBar --snapshot /tmp/runout-bar --demo --pointer 250,400` | The same screens with the pointer at that spot, to check a hover state |
| `scripts/package-release.sh` | The release build, the app bundle and the release zip |

CI runs the tests, the release packaging and the demo snapshots on every pull request, and
attaches the snapshots to the run.

`--pointer` takes points from the top left of the popover, which is 384 points wide; a snapshot
PNG is twice that size. It shows hover states only. Check what a click does in the demo app.

The tests of the reset script run a real `node` against a stand-in TeamClaude install. They skip
when `node` is not in `/opt/homebrew/bin`, `/usr/local/bin` or `/usr/bin`.

## Where things live

- `Sources/RunoutCore`: parsing, pace and run-out models, resets, the API queue, history, alerts
  and update logic. It has no interface code, and `Tests/RunoutCoreTests` covers it.
- `Sources/RunoutBar`: the status item, the popover and the SwiftUI views. `DemoData.swift` holds
  the made-up data for `--demo`.
- `scripts/`: build, install, release, icon and brand image scripts. `get.sh` is the installer
  the README's Quickstart pipes to `bash`; it must keep working when run that way.
- `docs/`: deeper documentation, the logo and the README images.

## Guidelines

- **Test the logic.** A change to `RunoutCore` comes with a test. Views are checked with the demo
  snapshots.
- **Keep real data out.** Fixtures, screenshots and issue text use made-up accounts such as
  `ada@example.com`. Never commit tokens, account names or a real `teamclaude status` output.
- **Never spend a real reset in a test.** A spend cannot be undone. Tests run the reset
  script against the stand-in TeamClaude install in `ClaudeResetsTests.swift`, and only parse
  recorded Codex answers.
- **Add no dependencies** without discussing it in an issue first.
- **Match the code around you**: 120 columns, doc comments that say what a thing is for, and no
  comments that restate the code.
- **Update the docs** when behavior changes: `README.md` for what a user sees, `docs/` for how it
  works.

A change to a view should update the README screenshots:

```bash
swift run RunoutBar --snapshot /tmp/runout-bar --demo
cp /tmp/runout-bar/{usage,proxy}-dark.png docs/screenshots/
cp /tmp/runout-bar/detail-personal-dark.png docs/screenshots/detail-dark.png
cp /tmp/runout-bar/glyph.png docs/screenshots/menubar.png
```

The README uses the dark renders as plain images. A `<picture>` that follows the reader's theme
does not load in the GitHub mobile app.

`swift scripts/make-icon.swift` redraws the app icon, and `swift scripts/make-brand.swift` the
README banner and the social preview. `docs/logo.svg` is the same drawing by hand; keep the three
in step.

## Pull requests

1. Branch from `main`.
2. Keep one change per pull request, with a title that says what changes for the user, such as
   `fix: keep the last chart label inside the card`.
3. Say in the description how you checked it. Add before and after snapshots for a view change.
4. CI must pass.

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).

## Releases

A maintainer publishes a release by setting `CFBundleShortVersionString` in `Resources/Info.plist`
through a pull request, then pushing a tag of the same version from `main`:

```bash
git tag v1.2.3 && git push origin v1.2.3
```

The Release workflow tests the tag, builds the app with `scripts/package-release.sh` and publishes
the zip and its SHA-256 file. The build is ad-hoc signed and not notarized, which is why the
README tells users how to allow it.

## Security issues

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).
