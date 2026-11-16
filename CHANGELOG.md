# Changelog

All notable changes to SnugBar are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - Unreleased

First public release. SnugBar needs macOS 27 or later.

### Added
- Three sections for menu bar items: Shown, Hidden (shown on demand) and Always Hidden. macOS 27 hides whole apps, so
  all items of an app share a section; Apple's clock and Control Center always stay.
- SnugBar's icon shows or hides hidden items; so do a global shortcut, a click on an empty part of the menu bar,
  resting the pointer on the bar, or scrolling on it. Items hide again after a delay, when you click elsewhere or
  when you switch apps.
- The SnugBar Bar, a panel under the menu bar that lists hidden items with their pictures; clicking one opens its
  real menu. Items that don't fit beside the notch go there under "Didn't Fit" instead of behind the system's
  overflow button.
- Search for any menu bar item by name, and open by letter: each item in the SnugBar Bar gets a key.
- Zen mode: hides every app's items except Apple's until you turn it off.
- Layout editor: drag items to reorder them or move apps between sections, select several at once, and add spacers.
  SnugBar puts items back where you arranged them after restarts, app relaunches, sleep, display changes and macOS
  updates, and keeps the last 20 layout backups.
- The `snugbar` command-line tool, a local MCP server for AI agents and `snugbar://` links, all with the same
  commands: list, search, show, hide, click, move, order, expand, collapse, toggle, swap, zen and status. An access
  token can be required.
- First-run setup that explains each permission, and a reduced mode that keeps basic hiding working without
  Device Control and Data Access (Accessibility before macOS 27).
- "Menu bar icon" setting with two styles: Chevrons (the default) and Capsule.
- Settings in one JSON file, with export and import.
- In-app updates with Sparkle: SnugBar checks GitHub once a day and can install the update and relaunch. "Check for
  Updates…" is in SnugBar's menu; automatic checks can be turned off in Settings > General.
- About SnugBar, with the version, the license and a link to the source.
- Signed and notarized DMG and zip.

[Unreleased]: https://github.com/0sahil/snugbar/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/0sahil/snugbar/releases/tag/v1.0.0
