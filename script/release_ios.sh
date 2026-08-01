#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and uploads the RunwayMobile iOS app to TestFlight. iOS has no notarization step —
# uploading to App Store Connect is the platform's equivalent: Apple processes the build and makes
# it available to TestFlight testers. Signing uses Xcode cloud signing (`-allowProvisioningUpdates`
# with an App Store Connect API key), so no certificate or provisioning profile secrets are needed;
# the key must have the App Manager role to create/refresh the cloud-managed Apple Distribution
# certificate and App Store profile. Runs in CI (release.yml) and locally on a Mac with the same
# env. The one-time App Store Connect setup lives in .agents/skills/release-swift/.
#
# Required env:
#   RUNWAY_VERSION        human version, e.g. 0.7.1 (CFBundleShortVersionString / MARKETING_VERSION).
#                         Shared with the macOS release: both platforms ship the tag's version.
#   APPLE_NOTARY_KEY_PATH / APPLE_NOTARY_KEY_ID / APPLE_NOTARY_ISSUER_ID
#                         App Store Connect API private key path, key ID, and issuer ID — the same
#                         key release.sh uses for notarization (App Manager role required here).
# Optional env:
#   RUNWAY_BUILD          CFBundleVersion (monotonic; TestFlight rejects reused build numbers per
#                         version). Default: git commit count, same scheme as the macOS app.
#   APPLE_TEAM_ID         defaults to 8KZBNZJBAX.
#   SKIP_TESTFLIGHT_UPLOAD=1  Export the signed .ipa into dist/ios/ instead of uploading, for a
#                         LOCAL dry run. Without it the build is uploaded to TestFlight.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${RUNWAY_VERSION:?set RUNWAY_VERSION, e.g. 0.7.1}"
: "${APPLE_NOTARY_KEY_PATH:?set APPLE_NOTARY_KEY_PATH to the App Store Connect API .p8 key}"
: "${APPLE_NOTARY_KEY_ID:?set APPLE_NOTARY_KEY_ID}"
: "${APPLE_NOTARY_ISSUER_ID:?set APPLE_NOTARY_ISSUER_ID}"

BUNDLE_ID="com.mattstallone.runway.mobile"
EXPECTED_TEAM_ID="${APPLE_TEAM_ID:-8KZBNZJBAX}"
VERSION="$RUNWAY_VERSION"
"$ROOT_DIR/script/validate_release_tag.sh" "v$VERSION" >/dev/null
# TestFlight orders builds by the monotonic CFBundleVersion within a CFBundleShortVersionString.
# The git commit count matches the macOS DMG's build number, so one tag produces one build number.
BUILD="${RUNWAY_BUILD:-$(git rev-list --count HEAD)}"

[ -f "$APPLE_NOTARY_KEY_PATH" ] || { echo "APPLE_NOTARY_KEY_PATH does not exist: $APPLE_NOTARY_KEY_PATH" >&2; exit 1; }
# xcodebuild resolves the key path against its own working directory; make it absolute.
KEY_PATH="$(cd "$(dirname "$APPLE_NOTARY_KEY_PATH")" && pwd)/$(basename "$APPLE_NOTARY_KEY_PATH")"

DIST_DIR="$ROOT_DIR/dist/ios"
ARCHIVE_PATH="$DIST_DIR/RunwayMobile.xcarchive"
EXPORT_OPTIONS="$DIST_DIR/ExportOptions.plist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

AUTH_FLAGS=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$APPLE_NOTARY_KEY_ID"
  -authenticationKeyIssuerID "$APPLE_NOTARY_ISSUER_ID"
)

echo "==> Archiving RunwayMobile $VERSION ($BUILD)"
xcodebuild \
  -project ios/RunwayMobile.xcodeproj \
  -scheme RunwayMobile \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  "${AUTH_FLAGS[@]}" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  archive

# Verify the archive is what we intend to ship before it goes anywhere near App Store Connect.
APP_PLIST="$ARCHIVE_PATH/Products/Applications/RunwayMobile.app/Info.plist"
for expected in \
  "CFBundleIdentifier=$BUNDLE_ID" \
  "CFBundleShortVersionString=$VERSION" \
  "CFBundleVersion=$BUILD"
do
  key="${expected%%=*}"; want="${expected#*=}"
  got="$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP_PLIST")"
  [ "$got" = "$want" ] || { echo "Archive $key is '$got', expected '$want'" >&2; exit 1; }
done
TEAM_IN_ARCHIVE="$(codesign -dvv "$ARCHIVE_PATH/Products/Applications/RunwayMobile.app" 2>&1 \
  | awk -F'[()]' '/^Authority=Apple Distribution/ {print $2; exit}')"
[ "$TEAM_IN_ARCHIVE" = "$EXPECTED_TEAM_ID" ] \
  || { echo "Archive is not signed by an Apple Distribution identity for team $EXPECTED_TEAM_ID (got: ${TEAM_IN_ARCHIVE:-none})" >&2; exit 1; }

if [ "${SKIP_TESTFLIGHT_UPLOAD:-}" = "1" ]; then
  DESTINATION="export"
  echo "WARNING: SKIP_TESTFLIGHT_UPLOAD=1 — exporting the .ipa locally instead of uploading." >&2
else
  DESTINATION="upload"
fi

# manageAppVersionAndBuildNumber stays false so the uploaded build number is exactly the git commit
# count above — App Store Connect must never rewrite it, or TestFlight builds and macOS DMGs from
# the same tag would disagree.
/usr/libexec/PlistBuddy -c "Clear dict" \
  -c "Add :method string app-store-connect" \
  -c "Add :destination string $DESTINATION" \
  -c "Add :teamID string $EXPECTED_TEAM_ID" \
  -c "Add :signingStyle string automatic" \
  -c "Add :uploadSymbols bool true" \
  -c "Add :manageAppVersionAndBuildNumber bool false" \
  "$EXPORT_OPTIONS" >/dev/null

echo "==> Exporting archive (destination: $DESTINATION)"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$DIST_DIR" \
  "${AUTH_FLAGS[@]}"

if [ "$DESTINATION" = "upload" ]; then
  echo "==> Uploaded RunwayMobile $VERSION ($BUILD) to App Store Connect."
  echo "    TestFlight serves it to internal testers once Apple finishes processing (usually minutes)."
else
  echo "==> Exported $(ls "$DIST_DIR"/*.ipa)"
fi
