# Distribution

## Channels

Atelier ships via two channels:

1. **Homebrew cask** (primary): `brew install --cask phaedryx/tap/atelier`
   - Installs the app and the `ff` CLI automatically
   - Upgrade: `brew upgrade --cask atelier`
2. **Direct DMG** via GitHub Releases
   - CLI available from Settings > Environment

## Update notification

Atelier has no in-app updater. `UpdateChecker` polls the GitHub Releases
API for `phaedryx/atelier` on launch and shows a sidebar badge when a newer
release is published; drafts and pre-releases are ignored.

Clicking the badge shows the `brew upgrade --cask atelier` command. DMG
users download the new release manually.

## Release flow

1. Merge conventional commits into `main`
2. release-please opens or updates a version bump PR
3. Merge the release PR
4. CI runs the `build` job:
   - Checkout with submodules, install XcodeGen
   - Build release with xcodebuild
   - Create temporary keychain, import signing certificate
   - Notarize via stored keychain profile
   - Create and sign DMG
   - Upload DMG to GitHub release
   - Update Homebrew cask in `phaedryx/homebrew-tap`
5. Users see the update badge on next app launch

## Required secrets

| Secret | Purpose |
|--------|---------|
| `CERTIFICATE_P12_BASE64` | Code signing certificate |
| `CERTIFICATE_PASSWORD` | Certificate password |
| `APPLE_ID` | Apple Developer account |
| `APPLE_TEAM_ID` | Team identifier |
| `APPLE_APP_PASSWORD` | App-specific password for notarization |
| `HOMEBREW_TAP_TOKEN` | PAT with `public_repo` scope for tap updates |
| `SIGNING_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `DEVELOPMENT_TEAM` | Apple Developer Team ID |

## Local release (manual)

```bash
./scripts/release.sh [version]
```

Builds, signs, notarizes, and creates a DMG locally. Version defaults
to the value in `.release-please-manifest.json` if not provided.

## Auto-update (not shipped)

The upstream project used Sparkle. This fork dropped it: the signing key
and appcast feed belonged to the original authors, and shipping an update
channel pointed at someone else's builds is worse than having none.

Restoring it means generating a new Ed25519 key pair with Sparkle's
`generate_keys`, hosting an appcast, and reinstating the Sparkle package
in `project.yml`.

## Release verification checklist

After a release, verify:

1. GitHub release exists with notarized DMG attached
2. Homebrew cask points to the new DMG
3. App shows the update badge when running an older version
