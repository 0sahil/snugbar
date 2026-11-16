# Releasing SnugBar (maintainers)

Releases are built by GitHub Actions (`.github/workflows/release.yml`): Developer ID signed with the hardened
runtime, notarized by Apple, stapled, packaged as a drag-to-Applications `.dmg` (also signed, notarized and stapled)
and a `.zip`, and attached to a **draft** GitHub release with their SHA-256 files and the Sparkle `appcast.xml` that
installed copies read to find updates.

## One-time setup

### 1. Developer ID Application certificate
An *Apple Distribution* certificate is for the App Store and won't work here.

1. developer.apple.com > Certificates, Identifiers & Profiles > Certificates > **+**
2. Choose **Developer ID Application** (Account Holder role required) and upload a certificate signing request from
   Keychain Access > Certificate Assistant > *Request a Certificate From a Certificate Authority…*
3. Download the certificate and open it, so it lands in your login keychain next to its private key.
4. Check: `security find-identity -v -p codesigning` lists `Developer ID Application: … (TEAMID)`.
5. Export it: Keychain Access > My Certificates > right-click the certificate > *Export…* > `.p12`, with a strong
   password.

### 2. App Store Connect API key (for notarization)
appstoreconnect.apple.com > Users and Access > Integrations > **App Store Connect API** > Team Keys > **+**, role
*Developer*. Download the `.p8` (it can be downloaded only once) and note the **Key ID** and the **Issuer ID**.

### 3. GitHub secrets
Set them yourself; never commit these files.

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 -R 0sahil/snugbar
gh secret set DEVELOPER_ID_P12_PASSWORD -R 0sahil/snugbar         # paste the .p12 password
base64 -i AuthKey_<KEY_ID>.p8 | gh secret set NOTARY_API_KEY_BASE64 -R 0sahil/snugbar
gh secret set NOTARY_API_KEY_ID -R 0sahil/snugbar                 # the Key ID
gh secret set NOTARY_API_ISSUER_ID -R 0sahil/snugbar              # the Issuer ID (a UUID)
```

Then delete the exported `.p12` (the certificate stays in your keychain) and keep the `.p8` somewhere safe.

### 4. Sparkle update signing key (EdDSA)
Updates are verified against the public key built into every copy (`SUPublicEDKey` in `scripts/build-app.sh`). The
private half lives in the maintainer's login keychain under the account `snugbar`. Sparkle's tools are in
`.build/artifacts/sparkle/Sparkle/bin/` after `swift package resolve`.

```sh
BIN=.build/artifacts/sparkle/Sparkle/bin
$BIN/generate_keys --account snugbar           # prints the public key (creates a pair only if there is none)
$BIN/generate_keys --account snugbar -x key.txt
gh secret set SPARKLE_ED_PRIVATE_KEY -R 0sahil/snugbar < key.txt
rm key.txt
```

The printed public key must equal `SUPublicEDKey`. **Back the private key up** (for example in a password manager,
from `generate_keys -x`): if it is lost, installed copies can never be updated again, because they only accept
updates signed with it. If it leaks, anyone who can serve the appcast can push an update.

## Cutting a release
1. Set `VERSION` (for example `1.0.1`) and move the `## [Unreleased]` notes in `CHANGELOG.md` under
   `## [1.0.1] - YYYY-MM-DD`, with the compare links at the bottom.
2. Commit, tag and push:
   ```sh
   git commit -am "Release 1.0.1"
   git tag v1.0.1 && git push origin main v1.0.1
   ```
3. Watch the *Release* workflow. It checks that the tag matches `VERSION` and that every secret is set, runs the
   tests, builds and notarizes, writes the appcast and creates the draft release.
4. Open the draft on GitHub, check the notes and the assets (`SnugBar-<version>.dmg`, `.zip`, both `.sha256` files,
   `appcast.xml`), and click **Publish**.
5. Update the Homebrew cask (below).

To rebuild an existing tag: Actions > Release > *Run workflow* with the tag name.

## Updates (Sparkle)
- `scripts/build-app.sh` embeds `Sparkle.framework` (without its XPC services, which only sandboxed apps need), adds
  the `@executable_path/../Frameworks` rpath, writes `SUFeedURL`
  (`https://github.com/0sahil/snugbar/releases/latest/download/appcast.xml`), `SUPublicEDKey` and
  `SUEnableAutomaticChecks`, and signs inside-out without `--deep`: Sparkle's `Autoupdate` and `Updater.app`, the
  framework, the command-line tool in `Contents/Helpers/snugbar`, then the app.
- After notarizing, the workflow runs `scripts/make-appcast.sh`. It signs `SnugBar-<version>.zip` with `sign_update`
  (key from `SPARKLE_ED_PRIVATE_KEY`, passed on stdin), checks the signature against the app's `SUPublicEDKey`, and
  writes `build/appcast.xml` with one item: `sparkle:version` is the built app's `CFBundleVersion` (the git commit
  count, which Sparkle compares), `sparkle:shortVersionString` is `VERSION`, `sparkle:minimumSystemVersion` is
  27.0.0, and the notes are this version's CHANGELOG section in Markdown. Updates download the zip, never the DMG.
- **Publishing is the gate.** `releases/latest/download/appcast.xml` resolves to the latest *published* release, so
  installed copies see a new version only once the draft is published.
- Users turn automatic checks off in Settings > General; "Check for Updates…" in SnugBar's menu always works.

### Testing an update locally
The user default `SnugBarUpdateFeedURL` overrides the feed. Signatures are still checked, so the zip must be signed
with the real key.

```sh
# 1. Build a "newer" app (more commits than the installed copy) and zip it, then write its appcast with the key
#    from your keychain:
scripts/build-app.sh
ditto -c -k --sequesterRsrc --keepParent build/SnugBar.app build/SnugBar-$(cat VERSION).zip
scripts/make-appcast.sh --keychain --notes-section Unreleased
# 2. Serve build/ and point the installed, older SnugBar at it:
sed -i '' "s#https://github.com/0sahil/snugbar/releases/download/v[^/]*/#http://127.0.0.1:8765/#" build/appcast.xml
(cd build && python3 -m http.server 8765) &
defaults write app.snugbar.SnugBar SnugBarUpdateFeedURL http://127.0.0.1:8765/appcast.xml
# 3. In SnugBar: Check for Updates… When you're done:
defaults delete app.snugbar.SnugBar SnugBarUpdateFeedURL
```

`SKIP_SIGN=1 scripts/make-appcast.sh` writes a placeholder signature to check the XML only; such an appcast installs
nothing.

## Local builds
```sh
brew install create-dmg                       # once
xcrun notarytool store-credentials snugbar    # once; interactive
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=snugbar scripts/package-release.sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" SKIP_NOTARIZE=1 scripts/package-release.sh  # sign only
SKIP_NOTARIZE=1 scripts/package-release.sh    # ad-hoc dry run of the packaging; not for distribution
```

The DMG step drives Finder with AppleScript, so the first run may ask to let your terminal control Finder.

Hardened runtime: `scripts/SnugBar.entitlements` is empty on purpose. SnugBar isn't sandboxed, the private framework
it loads lives in /System (library validation allows platform binaries), Sparkle is signed with the same identity,
and its permissions come from privacy settings, not entitlements.

## Homebrew cask
The cask lives in the tap `0sahil/homebrew-tap` as `Casks/snugbar.rb`. After publishing a release:

```sh
scripts/make-cask.sh 1.0.1 "$(cut -d' ' -f1 SnugBar-1.0.1.dmg.sha256)" > Casks/snugbar.rb   # in the tap
brew audit --cask --online 0sahil/tap/snugbar
brew install --cask 0sahil/tap/snugbar
```

The cask links the command-line tool (`binary` stanza for `Contents/Helpers/snugbar`), declares `auto_updates true`
(Sparkle updates the app; Homebrew doesn't need to) and lists the files `brew uninstall --zap` removes.

## If the membership lapses
Published releases keep working (their signatures carry a secure timestamp). New releases can't be signed or
notarized until the membership is renewed. Only revoking the certificate breaks existing installs.
