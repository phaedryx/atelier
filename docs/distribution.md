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

Releases are tag-driven. `CHANGELOG.md` is hand-maintained — nothing generates
it, so add the new version's entries before tagging or it silently rots.

1. Merge conventional commits into `main`
2. Update `CHANGELOG.md` for the new version and merge it
3. Tag and push: `git tag v0.2.0 && git push origin v0.2.0`
4. `.github/workflows/release.yml` runs the `build` job:
   - Derive the version from the tag (`vX.Y.Z` only; anything else fails fast)
   - Checkout with submodules, install XcodeGen
   - Stamp the version into `project.yml` (`scripts/set-version.sh`), then
     `xcodegen generate` — the bump is build-time only and never committed
   - Build release with xcodebuild
   - Create temporary keychain, import signing certificate
   - Notarize via stored keychain profile
   - Create and sign DMG
   - Create the GitHub release as a draft, upload the DMG, then publish it, so
     the update badge never points at a release with no asset
   - Update Homebrew cask in `phaedryx/homebrew-tap`
5. Users see the update badge on next app launch

Re-running the workflow (`workflow_dispatch` from the tag) reuses the existing
release and re-uploads the DMG with `--clobber`.

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

Builds, signs, notarizes, and creates a DMG locally. Version defaults to the
most recent `vX.Y.Z` tag reachable from HEAD. Uploading the DMG is manual; the
script prints the `gh release upload` command to run.

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
