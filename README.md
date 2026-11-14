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
- With Menu Bar folder access, tiles in the SnugBar Bar can be dragged: within Hidden or Always Hidden to reorder it,
  or onto the other group to move the app there. The order is saved like the layout editor's. Esc cancels a drag.
  "Didn't Fit" items and apps the order file doesn't know yet stay put, and so does everything in letter mode.
- When the menu bar has no room beside the notch, the leftmost shown apps move to the SnugBar Bar under "Didn't Fit"
  instead of going behind the system's overflow button (can be turned off).
- Optional shortcuts: a search palette for every menu bar item, "open by letter" (each item in the SnugBar Bar gets a
  key), and Zen mode, which hides every app's items except Apple's and SnugBar's until you turn it off.
- Settings live in `~/Library/Application Support/SnugBar/settings.json`, a plain JSON file.
- SnugBar must run from /Applications: macOS hides its icon along with other apps when it runs from elsewhere.

### Layout editor, spacers and backups

- **Edit Layout…** (in SnugBar's menu, and in Settings > Sections and Settings > Layout) opens a window with three rows:
  Shown, Hidden and Always Hidden, in menu bar order, with each item's picture (or its app's icon). Rest the pointer
  on a tile for its name.
- Drag within a row to reorder it; drag onto another row to move the app there (all items of an app move together).
  Click selects, ⌘-click adds or removes, ⇧-click selects a range within a row, ⌘A selects everything, Esc clears;
  dragging a selected tile moves the whole selection. Right-click offers "Move To" and, for spacers, "Remove Spacer".
  The clock and Control Center stay at the right end and can't be moved.
- With Menu Bar folder access, items move without the pointer moving. Without it, reordering Shown in the editor
  uses a quick ⌘-drag of the pointer, and Hidden and Always Hidden can't be reordered (their items aren't on screen to
  drag). Their order is kept in the order file, so it shows when the section is expanded and in the SnugBar Bar.
- **Spacers** are empty gaps (1–64 pt, default 16) owned by SnugBar. Add them with **Add Spacer**, drag them like items,
  set the width of a selected spacer under the rows. They live in Shown only, and are not listed in the SnugBar Bar,
  search, open by letter or `snugbar list`. Zen mode shrinks them to nothing until it ends; they keep their place.
- SnugBar keeps the order you arranged: after it starts, when an app relaunches, after sleep, when displays change
  and after a macOS update it puts items back where they were. These automatic checks only write the order file; they
  never move the pointer, so without folder access they leave the order alone. Moving items by hand with ⌘-drag in
  the menu bar still works, and the new order is kept.
- New apps go to the section chosen in Settings > Sections (default Hidden); SnugBar's menu says once where each new
  app went.
- **Backups:** before every change to the item order, and before a reset, a restore, an import or a check after a macOS
  update, SnugBar saves the system positions and its own layout (sections, order, spacers) in
  `~/Library/Application Support/SnugBar/backups`, keeping the last 20. Settings > Layout lists them with **Restore**
  and **Show in Finder**, and has **Reset Layout…** (every app back in the default section, no kept order, no spacers).
- **Export Settings… / Import Settings…** in Settings > General save or load the settings file. An import is checked
  first (a file from a newer SnugBar is refused) and the layout is backed up before it applies. The access token and
  the Menu Bar folder access are never part of the file.

## Command line, AI agents and links

SnugBar runs one small HTTP server on 127.0.0.1 (port 47811 by default; change the port or turn it off in
Settings > Control). The `snugbar` command-line tool and MCP clients such as AI agents both connect through it, so
turning it off stops both; `snugbar://` links don't use it. All three use the same commands:

| Command | What it does |
|---|---|
| `list [--section shown\|hidden\|alwaysHidden]` | Items with their section and whether they are on screen |
| `search <query>` | Fuzzy search by app and item name, best match first |
| `show <item>` / `hide <item>` | Show one app's items for a while / hide them again now |
| `click <item>` | Open an item's menu (shows it first if it is hidden) |
| `move <item>... <section>` | Move one or more apps to a section; all items of an app move together |
| `order <item> --before <item>` (or `--after`) | Reorder a shown item; SnugBar keeps the new order |
| `expand`, `collapse`, `toggle`, `swap` | Show or hide the Hidden section, or swap Shown and Hidden |
| `zen [on\|off\|toggle]` | Zen mode |
| `status` | Hiding and arranging methods, permissions, version, port, token |

`<item>` is an item ID from `snugbar list`, an app's bundle ID, or part of an app or item name. When a name matches
several items, the error lists them with their IDs. `move` takes several items at once (MCP and HTTP: an `items`
array instead of `item`); SnugBar looks them all up first, and if any isn't found or is ambiguous, nothing moves.

### Command-line tool

The tool is inside the app at `SnugBar.app/Contents/Helpers/snugbar`. Settings > Control > Install Command-Line Tool…
shows the exact commands to link it into your PATH, for example:

```sh
mkdir -p ~/.local/bin && ln -sf /Applications/SnugBar.app/Contents/Helpers/snugbar ~/.local/bin/snugbar
```

```sh
snugbar list
snugbar list --section hidden --json
snugbar move "Some App" alwaysHidden
snugbar move chat weather hidden      # several apps; the last word is the section
snugbar click com.example.app
snugbar zen on
snugbar --help            # all commands; snugbar <command> --help for one
```

Output is plain text; `--json` prints the server's JSON instead. `--port N` (or `SNUGBAR_PORT`) picks another port;
otherwise the tool uses the port from SnugBar's settings. Exit status: 0 success, 1 the command failed, 2 usage error,
3 SnugBar not reachable.

### AI agents (MCP)

The MCP endpoint is `http://127.0.0.1:47811/mcp` (Streamable HTTP with JSON responses). Each command is a tool named
`snugbar_<command>`. Settings > Control shows these lines with your port and token, with Copy buttons.

Claude Code:

```sh
claude mcp add --transport http snugbar http://127.0.0.1:47811/mcp
```

Hermes (`config.yaml`):

```yaml
mcp_servers:
  snugbar:
    url: http://127.0.0.1:47811/mcp
```

### Access token

Off by default. When you turn on "Require an access token" in Settings > Control, SnugBar creates a random token in
`~/Library/Application Support/SnugBar/token` (readable only by you), and every request must send
`Authorization: Bearer <token>`. The `snugbar` tool reads the file by itself. For agents, add the header:

```sh
claude mcp add --transport http snugbar http://127.0.0.1:47811/mcp --header "Authorization: Bearer <token>"
```

```yaml
mcp_servers:
  snugbar:
    url: http://127.0.0.1:47811/mcp
    headers:
      Authorization: Bearer <token>
```

Turning the token off stops checking it but keeps the file; "Regenerate" replaces it.

### HTTP API

`POST /v1/<command>` with a JSON body of string arguments (`item`, `section`, `before`, `after`, `query`, `state`,
and for `move` an `items` array of strings);
`GET /v1/status` works too. Every answer is a JSON object with `ok`, and on failure
`error: {code, message, candidates?}` with codes such as `not_found`, `ambiguous`, `invalid_argument`,
`unavailable`, `locked` (Zen mode is on) and `unauthorized`.

```sh
curl -s -X POST http://127.0.0.1:47811/v1/move -d '{"item": "com.example.app", "section": "hidden"}'
```

The server only listens on 127.0.0.1, only answers requests whose `Host` is `127.0.0.1:<port>` or `localhost:<port>`,
and refuses requests from web pages (an `Origin` header that isn't a loopback address).

### Links

```text
snugbar://expand
snugbar://zen?state=on
snugbar://click?item=com.example.app
snugbar://move?item=com.example.app&section=alwaysHidden
snugbar://move?item=com.example.app&item=com.example.other&section=hidden
snugbar://move?items=com.example.app,com.example.other&section=hidden
snugbar://order?item=com.example.app&before=com.example.other
```

Links take the same arguments as query parameters. `list`, `search` and `status` links just run (their result isn't
shown anywhere). The first time another app opens a link that changes something, SnugBar asks whether to allow that
app and remembers the answer; when it can't tell which app sent the link, it asks every time. Settings > Control >
Links > Reset forgets the answers.

## First run and permissions

The first time SnugBar starts, a short setup window explains each permission, shows whether it is allowed, and has a
button that opens the right place in System Settings. Each page can be skipped; the setup can be opened again from
SnugBar's menu (Set Up SnugBar…) or from Settings > Permissions (Show Setup Again…). The status updates by itself while
the window is open, and a newly allowed permission takes effect without restarting SnugBar (Screen Recording is the
exception: macOS often applies it only after a restart, so SnugBar offers a Restart button).

| Permission | Used for | Without it |
|---|---|---|
| Accessibility (required) | Reading the menu bar and opening items | Reduced mode: only basic hide and show (the icon, shortcuts, and `expand`, `collapse`, `toggle`, `swap`, `zen`, `move`) |
| Screen Recording (optional) | Pictures of items in the SnugBar Bar and the layout editor | App icons instead; everything else works |
| Menu Bar folder (optional) | Reordering items without moving the pointer (chosen once in an open panel) | Reordering moves the pointer briefly |

In reduced mode SnugBar's icon shows a warning and its menu starts with "Accessibility Needed…". The SnugBar Bar,
search, open by letter, the layout editor, showing items by clicking, hovering or scrolling on the menu bar, and opening
Notification Center from the clock while items are hidden are unavailable; hidden items are shown in the menu bar
instead. `click` and `order` answer with an `unavailable` error, `list` and `search` list the apps SnugBar already knows
(from its settings and running apps) without live positions, and `status` adds `reducedMode` and an `unavailable` list.
SnugBar checks Accessibility every few seconds, so allowing or removing it while SnugBar runs takes effect on its own.

SnugBar collects no usage data and doesn't send anything over the network. Its control server listens on 127.0.0.1
only, and its settings are one JSON file in `~/Library/Application Support/SnugBar`.

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

`serve --fake --port <N> [--seconds <S>] [--token-file <path>] [--grants <list|none>]` runs the real HTTP/MCP server on 127.0.0.1:N for S
seconds (default 30) with made-up items and an in-memory state: nothing on screen changes, so it can run next to the
installed SnugBar. With `--token-file`, requests need the token in that file. The output lists the requests and what
the fake engine was asked to do.

Read-only layout commands: `layout-snapshot --fake --out <png> [--dragging]` renders the layout editor offscreen with
made-up items; `bar-snapshot --fake --out <png> [--dragging] [--onto-other] [--no-access] [--width <pt>]` renders the
SnugBar Bar the same way (`--dragging`: mid-drag; `--width`: narrow enough to wrap); `settings-snapshot --pane layout --out <png>` renders the Layout settings pane;
`reconcile --dry-run [--settings <path>] [--trigger <name>] [--explicit] --out <file>` reports what a layout check
would write (order-file values, spacer positions, ⌘-drag moves for `--explicit`) or why it would skip, without
writing anything; `backups [--dir <dir>] --out <file>` lists layout backups.

Read-only setup commands, with made-up permissions given as `--grants none` or a comma list of `accessibility`,
`screenRecording` and `orderFile`: `setup-snapshot --step <welcome|accessibility|screenRecording|menuBarFolder|done>
--grants <...> --out <png>` renders a setup page; `settings-snapshot --pane permissions --grants <...> --out <png>`
renders the Permissions pane (`--size WxH` for a taller window, `--hover` to show the hover delay slider in General);
`menu-snapshot --grants <...> --out <txt>` writes SnugBar's menu as text; `availability --grants <...> --out <json>`
lists what works. `permissions --out <json>` reports the permissions of the copy that runs it. None of them asks for a
permission.

Captured item images are cached as raw crops in `~/Library/Caches/<bundle id>/ItemImages`; the menu bar background is
keyed out when they are loaded, so they are drawn as template images in the label colour.

## License

MIT. See [LICENSE](LICENSE).
