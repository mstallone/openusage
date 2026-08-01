#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and uploads the RunwayMobile iOS app to TestFlight. iOS has no notarization step —
# uploading to App Store Connect is the platform's equivalent: Apple processes the build and makes
# it available to TestFlight testers. Signing is MANUAL with an Apple Distribution certificate
# (imported into the keychain beforehand) and an App Store provisioning profile, mirroring the
# macOS release's cert+profile secrets. Cloud signing is deliberately not used: an App Manager API
# key cannot use cloud-managed distribution certificates ("Cloud signing permission error"), so the
# API key here only authenticates the upload itself. Runs in CI (release.yml) and locally on a Mac
# with the same env. The one-time App Store Connect setup lives in .agents/skills/release-swift/.
#
# Required env:
#   RUNWAY_VERSION        human version, e.g. 0.7.1 (CFBundleShortVersionString / MARKETING_VERSION).
#                         Shared with the macOS release: both platforms ship the tag's version.
#   IOS_PROVISIONING_PROFILE  path to the App Store provisioning profile (.mobileprovision) for
#                         com.mattstallone.runway.mobile, matching the imported distribution cert.
#   APPLE_NOTARY_KEY_PATH / APPLE_NOTARY_KEY_ID / APPLE_NOTARY_ISSUER_ID
#                         App Store Connect API private key path, key ID, and issuer ID — the same
#                         key release.sh uses for notarization; used here only to upload.
# Optional env:
#   RUNWAY_BUILD          CFBundleVersion (monotonic; TestFlight rejects reused build numbers per
#                         version). Default: git commit count, same scheme as the macOS app.
#   APPLE_TEAM_ID         defaults to 8KZBNZJBAX.
#   SKIP_TESTFLIGHT_UPLOAD=1  Export the signed .ipa into dist/ios/ instead of uploading, for a
#                         LOCAL dry run. Without it the build is uploaded to TestFlight.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${RUNWAY_VERSION:?set RUNWAY_VERSION, e.g. 0.7.1}"
: "${IOS_PROVISIONING_PROFILE:?set IOS_PROVISIONING_PROFILE to the App Store .mobileprovision path}"
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

[ -f "$IOS_PROVISIONING_PROFILE" ] || { echo "IOS_PROVISIONING_PROFILE does not exist: $IOS_PROVISIONING_PROFILE" >&2; exit 1; }
PROFILE_PLIST="$(security cms -D -i "$IOS_PROVISIONING_PROFILE")"
PROFILE_UUID="$(printf '%s' "$PROFILE_PLIST" | plutil -extract UUID raw -o - -)"
PROFILE_NAME="$(printf '%s' "$PROFILE_PLIST" | plutil -extract Name raw -o - -)"
PROFILE_APP_ID="$(printf '%s' "$PROFILE_PLIST" | plutil -extract Entitlements.application-identifier raw -o - -)"
[ "$PROFILE_APP_ID" = "$EXPECTED_TEAM_ID.$BUNDLE_ID" ] \
  || { echo "Provisioning profile is for '$PROFILE_APP_ID', expected '$EXPECTED_TEAM_ID.$BUNDLE_ID'" >&2; exit 1; }
# xcodebuild only picks up profiles installed in the user's profile directory.
PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILES_DIR"
cp "$IOS_PROVISIONING_PROFILE" "$PROFILES_DIR/$PROFILE_UUID.mobileprovision"

DIST_DIR="$ROOT_DIR/dist/ios"
ARCHIVE_PATH="$DIST_DIR/RunwayMobile.xcarchive"
EXPORT_OPTIONS="$DIST_DIR/ExportOptions.plist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Upload authentication only — signing never touches the portal.
AUTH_FLAGS=(
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$APPLE_NOTARY_KEY_ID"
  -authenticationKeyIssuerID "$APPLE_NOTARY_ISSUER_ID"
)

echo "==> Archiving RunwayMobile $VERSION ($BUILD) with profile '$PROFILE_NAME'"
xcodebuild \
  -project ios/RunwayMobile.xcodeproj \
  -scheme RunwayMobile \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  DEVELOPMENT_TEAM="$EXPECTED_TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
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
# Capture first, then parse: awk's early exit would SIGPIPE codesign and trip pipefail.
CODESIGN_INFO="$(codesign -dvv "$ARCHIVE_PATH/Products/Applications/RunwayMobile.app" 2>&1)"
TEAM_IN_ARCHIVE="$(printf '%s\n' "$CODESIGN_INFO" \
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
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$EXPECTED_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$BUNDLE_ID</key><string>$PROFILE_NAME</string>
  </dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
plutil -lint "$EXPORT_OPTIONS" >/dev/null

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
