# Security policy

## What SnugBar can do
With the permissions you give it, SnugBar reads the menu bar, opens menu bar items with synthetic clicks, captures
pictures of menu bar items and, with Menu Bar folder access, changes the order of items. Its control server lets local
programs (the `snugbar` tool, AI agents, scripts) list, show, hide, click and move menu bar items.

Built-in protections:
- The control server listens on `127.0.0.1` only; other machines can't reach it.
- Requests with an `Origin` header that isn't a loopback address are refused, so web pages in your browser can't
  call it.
- The `Host` header is checked to block DNS rebinding.
- An access token can be required (Settings > Control); the token file is readable only by you.
- `snugbar://` links that change something ask once per calling app.
- The server can be turned off in Settings > Control.
- Updates are verified with an EdDSA signature against a public key built into the app, on top of Apple's code
  signing and notarization.

Not protected against: other software already running on your Mac as your user. Such software can already control
your Mac the same ways, so SnugBar doesn't try to defend against it.

## Reporting a vulnerability
Please **do not** open a public issue. Use GitHub's private
[security advisory form](https://github.com/0sahil/snugbar/security/advisories/new) instead.
You'll get a response within a few days. Please include steps to reproduce and the SnugBar version.

## Supported versions
Only the latest release receives security fixes.
