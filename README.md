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

## License

MIT. See [LICENSE](LICENSE).
