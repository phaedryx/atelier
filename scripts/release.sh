#!/usr/bin/env bash
# ABOUTME: Builds, signs, notarizes, and packages Atelier as a DMG.
# ABOUTME: Usage: ./scripts/release.sh <version>   e.g. ./scripts/release.sh 0.2.0

set -euo pipefail

# Signing credentials belong to whoever ships the build, so they come from the
# environment rather than being baked in. Export these before running:
#   ATELIER_SIGNING_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)"
#   ATELIER_TEAM_ID           your Apple Developer Team ID
SIGNING_IDENTITY="${ATELIER_SIGNING_IDENTITY:-}"
TEAM_ID="${ATELIER_TEAM_ID:-}"
if [ -z "$SIGNING_IDENTITY" ] || [ -z "$TEAM_ID" ]; then
  echo "Error: set ATELIER_SIGNING_IDENTITY and ATELIER_TEAM_ID before releasing." >&2
  echo "       Find them with: security find-identity -v -p codesigning" >&2
  exit 1
fi
NOTARIZE_PROFILE="atelier"
APP_NAME="Atelier"
SCHEME="Atelier"
PROJECT="Atelier.xcodeproj"
# The git tag is the source of truth for the version, and origin has none yet,
# so there is nothing safe to infer from here. Make the caller say it.
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Error: pass the version explicitly: $0 0.2.0" >&2
  exit 1
fi
DMG_NAME="${SCHEME}.dmg"
BUILD_DIR="build/release"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"

echo "==> Building ${APP_NAME} v${VERSION}..."
# set-version.sh rewrites the tracked project.yml, so put it back on the way out
# rather than leaving a stray version bump staged in the working tree.
trap 'git checkout -- project.yml 2>/dev/null || true' EXIT
"$(dirname "${BASH_SOURCE[0]}")/set-version.sh" "$VERSION" >/dev/null
xcodegen generate
rm -rf "$BUILD_DIR/derived"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  build

# Copy the app out of DerivedData
APP_BUILT=$(find "$BUILD_DIR/derived" -name "${APP_NAME}.app" -type d | head -1)
if [ -z "$APP_BUILT" ]; then
  echo "Error: Built app not found"
  exit 1
fi
rm -rf "$APP_PATH"
mkdir -p "$BUILD_DIR"
cp -R "$APP_BUILT" "$APP_PATH"

echo "==> Re-signing embedded frameworks and helpers..."

# Re-sign all embedded frameworks with secure timestamp and hardened runtime
find "$APP_PATH/Contents/Frameworks" -type f -perm +111 -o -name "*.dylib" | while read -r bin; do
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options=runtime "$bin"
done

# Re-sign helpers with hardened runtime and secure timestamp
find "$APP_PATH/Contents/Helpers" -type f -perm +111 | while read -r bin; do
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options=runtime "$bin"
done

# Sign the main app binary (not --deep, nested code is already signed above)
codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options=runtime \
  --entitlements Resources/atelier.entitlements "$APP_PATH"

echo "==> Verifying signature..."
codesign --verify --verbose=2 --deep --strict "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1

echo "==> Creating DMG..."
rm -f "$BUILD_DIR/$DMG_NAME"
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"

# create-dmg exits non-zero when skipping deprecated internet-enable
create-dmg \
  --volname "$APP_NAME" \
  --background "Resources/dmg-background@2x.png" \
  --window-size 660 500 \
  --icon-size 128 \
  --icon "${APP_NAME}.app" 170 190 \
  --app-drop-link 490 190 \
  --no-internet-enable \
  "$BUILD_DIR/$DMG_NAME" \
  "$DMG_STAGING" || true

if [ ! -f "$BUILD_DIR/$DMG_NAME" ]; then
  echo "Error: DMG was not created"
  exit 1
fi

codesign --sign "$SIGNING_IDENTITY" "$BUILD_DIR/$DMG_NAME"

echo "==> Notarizing..."
xcrun notarytool submit "$BUILD_DIR/$DMG_NAME" \
  --keychain-profile "$NOTARIZE_PROFILE" \
  --wait

echo "==> Stapling..."
xcrun stapler staple "$BUILD_DIR/$DMG_NAME"

echo ""
echo "Done! DMG ready at: $BUILD_DIR/$DMG_NAME"
echo "Upload to GitHub release: gh release upload v${VERSION} $BUILD_DIR/$DMG_NAME"
