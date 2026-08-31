# Distribution

## Channels

Atelier ships one way: a **DMG attached to the GitHub release** for each
`vX.Y.Z` tag. Install the `atl` CLI afterwards from Settings > Environment.

There is no Homebrew cask. There was one (`phaedryx/tap/atelier`), inherited
from Factory Floor, but a cask is only worth maintaining for an app people can
install without fighting Gatekeeper — see below. There is no update checking of
any kind either; see [Auto-update (not shipped)](#auto-update-not-shipped).

## Builds are not notarized

Releases are **ad-hoc signed and not notarized**. This is a personal project and
notarization requires a paid Apple Developer account, which this project does
not have. A free Apple ID cannot notarize — it grants a Personal Team that can
sign for local development only.

Ad-hoc signing (`codesign --sign -`) is not optional and is not a substitute:
arm64 binaries will not execute at all without at least an ad-hoc signature. It
just carries no identity, so macOS cannot tell who built the app.

What that costs, in practice:

- **A locally built app runs normally.** Gatekeeper acts on the quarantine
  attribute, which macOS attaches to downloads. A build you produced yourself
  never has one, so `./scripts/dev.sh release` output can be copied straight
  into `/Applications` and opened.
- **A downloaded DMG is quarantined**, so the first launch is refused. Clear it
  once, either way:

  ```console
  # Right-click the app in /Applications and choose Open, then confirm.
  # Or, equivalently:
  xattr -dr com.apple.quarantine /Applications/Atelier.app
  ```

The release workflow prepends this note to every release body, so nobody has to
find this file first.

If the project ever wants downloads that just work, the missing piece is a
Developer ID certificate plus notarization — at which point the signing steps
removed in `chore/unsigned-releases` need restoring, along with the
`CERTIFICATE_P12_BASE64`, `CERTIFICATE_PASSWORD`, `SIGNING_IDENTITY`,
`DEVELOPMENT_TEAM`, `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`
secrets.

## Release flow

Releases are tag-driven. `CHANGELOG.md` is hand-maintained — nothing generates
it, so add the new version's entries before tagging or it silently rots.

1. Merge the work into `main`
2. Update `CHANGELOG.md` for the new version and merge it
3. Tag and push: `git tag v0.2.0 && git push origin v0.2.0`
4. `.github/workflows/release.yml` runs the `build` job:
   - Derive the version from the tag (`vX.Y.Z` only; anything else fails fast)
   - Checkout with submodules, install XcodeGen and Zig, build Ghostty and Monaco
   - Stamp the version into `project.yml` (`scripts/set-version.sh`), then
     `xcodegen generate` — the bump is build-time only and never committed
   - Build Release with xcodebuild, ad-hoc signed with the hardened runtime
   - Package the DMG (nothing is re-signed; `cp -R` preserves what xcodebuild
     already signed)
   - Create the GitHub release as a draft, upload the DMG, prepend the
     not-notarized note to the body, then publish — so the release is never
     visible without its asset
5. Users download the DMG from the release page and clear quarantine once

Re-running the workflow (`workflow_dispatch` from the tag) reuses the existing
release and re-uploads the DMG with `--clobber`.

## Required secrets

None. The workflow uses the automatic `GITHUB_TOKEN` for the release.

`SENTRY_AUTH_TOKEN` (with the `SENTRY_ORG` / `SENTRY_PROJECT` variables) is
optional: set it to upload dSYMs for crash symbolication. That step warns and
continues when it is missing, so it never fails a release.

## Local release (manual)

```bash
./scripts/dev.sh release        # ad-hoc signed Release build, no DMG
```

The result is at `build/release-local/derived/Build/Products/Release/Atelier.app`
and can be copied straight into `/Applications`.

`./scripts/release.sh <version>` also exists, and still expects a Developer ID:
it requires `ATELIER_SIGNING_IDENTITY` and `ATELIER_TEAM_ID` and refuses to run
without them. It is kept for whenever this project has a certificate, and is
unusable until then.

## Auto-update (not shipped)

The upstream project used Sparkle. This fork dropped it: the signing key
and appcast feed belonged to the original authors, and shipping an update
channel pointed at someone else's builds is worse than having none.

Restoring it means generating a new Ed25519 key pair with Sparkle's
`generate_keys`, hosting an appcast, and reinstating the Sparkle package
in `project.yml`. Note that Sparkle updating an unsigned app is its own
problem — Sparkle verifies signatures before swapping the bundle.

## Release verification checklist

After a release, verify:

1. The GitHub release exists with the DMG attached, and is not a draft
2. The release body leads with the not-notarized note
3. Mounting the DMG and dragging to `/Applications`, then right-click > Open,
   launches the app
