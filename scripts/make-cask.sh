#!/usr/bin/env bash
# Prints the Homebrew cask for a release, for the tap (0sahil/homebrew-tap, Casks/snugbar.rb).
#   scripts/make-cask.sh <version> <dmg-sha256>
#   scripts/make-cask.sh 1.0.0 "$(cut -d' ' -f1 build/SnugBar-1.0.0.dmg.sha256)" > snugbar.rb
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: scripts/make-cask.sh <version> <dmg-sha256>" >&2
    exit 2
fi
VERSION="$1"
SHA256="$(printf '%s' "$2" | tr 'A-F' 'a-f')"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]] || { echo "not a version: $VERSION" >&2; exit 2; }
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "not a SHA-256: $2" >&2; exit 2; }

BUNDLE_ID="app.snugbar.SnugBar"

# macOS 27 is :golden_gate in Homebrew's MacOSVersion table.
cat <<RUBY
cask "snugbar" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/0sahil/snugbar/releases/download/v#{version}/SnugBar-#{version}.dmg"
  name "SnugBar"
  desc "Menu bar manager with search, a command-line tool and an MCP server"
  homepage "https://github.com/0sahil/snugbar"

  livecheck do
    url :url
    strategy :github_latest
  end

  # SnugBar updates itself with Sparkle.
  auto_updates true
  depends_on macos: ">= :golden_gate"

  app "SnugBar.app"
  binary "#{appdir}/SnugBar.app/Contents/Helpers/snugbar"

  # Quitting lifts SnugBar's hide, so the menu bar is whole again.
  uninstall quit: "$BUNDLE_ID"

  zap trash: [
    "~/Library/Application Support/SnugBar",
    "~/Library/Caches/$BUNDLE_ID",
    "~/Library/HTTPStorages/$BUNDLE_ID",
    "~/Library/Preferences/$BUNDLE_ID.plist",
    "~/Library/Saved Application State/$BUNDLE_ID.savedState",
  ]
end
RUBY
