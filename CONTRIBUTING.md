# Contributing to SnugBar

Bug reports, ideas and pull requests are welcome.

## Before you start
- For anything bigger than a small fix, please open an issue first so we can agree on the approach.
- Check existing issues to avoid duplicates.

## Development setup
Requirements: macOS 27 or later and Xcode 27 or later (for the macOS 27 SDK).

```sh
git clone https://github.com/0sahil/snugbar.git
cd snugbar
swift build                 # debug build
swift test                  # unit tests
scripts/build-app.sh        # build/SnugBar.app, signed ad-hoc
```

Only one SnugBar can manage the menu bar at a time. Quit an installed copy before you run your own build, and run
it from /Applications (`scripts/build-app.sh --install`): macOS hides SnugBar's own icon along with other apps when it
runs from elsewhere. With ad-hoc signing every build has a new signature, so macOS may ask for permissions again.

The `--debug` commands described in the README render Settings, the menu, the SnugBar Bar and the layout editor
offscreen, or run the control server with made-up items, without touching the menu bar. They are the easiest way to
check a UI change next to an installed copy.

## Project layout
- `Sources/SnugBarCore/`: logic with no AppKit (settings and migrations, sections, layout planning, search, the
  command router, HTTP and MCP). Put testable logic here.
- `Sources/SnugBarEngine/`: reading the menu bar, hiding, clicking and arranging items, item pictures.
- `Sources/SnugBar/`: the app (status item, SnugBar Bar, search, Settings, layout editor, control server, updates).
- `Sources/SnugBarCLI/`: the `snugbar` command-line tool.
- `Tests/`: unit tests for SnugBarCore and parts of SnugBarEngine.
- `scripts/`: building, packaging and release tooling (see [docs/RELEASING.md](docs/RELEASING.md)).

## Pull requests
- Keep pull requests focused: one change each.
- Add or update tests for logic changes in SnugBarCore.
- `swift build`, `swift test` and `scripts/build-app.sh` must pass (CI runs all three).
- For UI changes, include a screenshot or a short recording. SnugBar uses plain, native macOS controls.
- Add a line under `## [Unreleased]` in `CHANGELOG.md`.
- New commands need a `CommandRouter` test, CLI help, an MCP tool description and a row in the README table.
- Settings changes that old files can't express need a schema migration in `SettingsMigration`, with a test.

## Code style
- Swift 5 language mode, Swift API design guidelines.
- Main actor for anything that touches UI or app state; keep SnugBarCore free of AppKit.
- Prefer clear names over comments; comment the why for anything that isn't obvious.

## License
By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
