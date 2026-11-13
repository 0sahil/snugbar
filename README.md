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
`move <item> --before <item>` (or `--after`), `capture <dir>`, `order-file`. Use absolute paths for `--out`
and `capture`. `hide`, `click` and `move` change the live menu bar.

## License

MIT. See [LICENSE](LICENSE).
