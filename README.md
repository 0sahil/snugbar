# SnugBar

SnugBar is a free, open-source menu bar manager for macOS. It hides the menu bar items you don't need and
keeps the rest tidy, using the way the macOS 27 menu bar works.

Status: early development, macOS 27 only. Nothing here is ready for everyday use yet.

## Building

Requirements: macOS 27 and Xcode with Swift 6 or later.

```sh
swift build            # debug build
swift test             # unit tests
scripts/build-app.sh   # release build, assembled and signed as build/SnugBar.app
```

`scripts/build-app.sh` signs ad-hoc by default. Set `SNUGBAR_SIGN_IDENTITY` to sign with your own identity.
`scripts/build-app.sh --install` also copies the app to /Applications.

## Using SnugBar

- Click SnugBar's icon to show or hide hidden items. Right-click it (or ⌃/⌥-click) for the menu.
- Settings: choose Settings… from the menu, or open SnugBar again from Applications or Spotlight (the way back
  when the icon is turned off).
- Sections are per app: **Shown**, **Hidden** (shown on demand) and **Always Hidden**. macOS 27 hides whole apps, so
  all items of one app share a section. Apple's own items always stay visible.
- Other ways to show hidden items, each optional: a global shortcut, clicking an empty part of the menu bar, resting
  the pointer on the bar, or scrolling on it. Items hide again after a delay, when you click elsewhere, or when you
  switch apps.
- By default, hidden items open in the SnugBar Bar, a small panel under the menu bar; click an item there to open
  its menu. Settings > General can switch this back to showing them in the menu bar itself.
- When the menu bar has no room beside the notch, the leftmost shown apps move to the SnugBar Bar under "Didn't Fit"
  instead of going behind the system's overflow button (can be turned off).
- Optional shortcuts: a search palette for every menu bar item, "open by letter" (each item in the SnugBar Bar gets a
  key), and Zen mode, which hides every app's items except Apple's and SnugBar's until you turn it off.
- Settings live in `~/Library/Application Support/SnugBar/settings.json`, a plain JSON file.
- SnugBar must run from /Applications: macOS hides its icon along with other apps when it runs from elsewhere.

## Permissions

- Accessibility (required): reading the menu bar and opening items.
- Screen Recording (optional): images of menu bar items.
- Menu bar layout access (optional): chosen once in an open panel, lets SnugBar reorder items without moving the
  pointer.

## Debug commands

The app can run one engine command without its menu and write the result as JSON:

```sh
open -W -n build/SnugBar.app --args --debug status --out /tmp/snugbar-status.json
```

Commands: `status`, `list`, `hide <seconds> [bundle ids to keep]`, `click <item>`,
`move <item> --before <item>` (or `--after`), `capture <dir>`, `order-file`, and `input key|click|move|scroll ...`
(synthetic events for on-device tests). Use absolute paths for `--out` and `capture`. `hide`, `click`, `move` and
`input` change the live menu bar or send real input to the frontmost app.

Read-only commands for the SnugBar Bar and search: `fit-plan` (menu bar room, shown widths and what would go to
"Didn't Fit"), `search <query>` (ranked results), `letters [--all]` (keys for open by letter) and
`bar-items [--all]` (what the SnugBar Bar lists, per tile, with each item's image source). `--all` includes Always
Hidden items. An app whose items have no captured image yet gets one tile in the bar; it opens the app's leftmost item.

Captured item images are cached as raw crops in `~/Library/Caches/<bundle id>/ItemImages`; the menu bar background is
keyed out when they are loaded, so they are drawn as template images in the label colour.

## License

MIT. See [LICENSE](LICENSE).
