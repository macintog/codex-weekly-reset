#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$ROOT_DIR/dist/Codex Weekly Reset.app}"
EXPECTED_BUNDLE_ID="com.macintog.codexweeklyreset"
EXPECTED_TEAM_ID="${CODEX_WEEKLY_RESET_APPLE_TEAM_ID:-A9FAXYYTNZ}"
SPARKLE_ACCOUNT="${CODEX_WEEKLY_RESET_SPARKLE_ACCOUNT:-ed25519}"
DOWNLOAD_URL_PREFIX="https://macintog.github.io/codex-weekly-reset/downloads/"
PRODUCT_URL="https://macintog.github.io/codex-weekly-reset/"
WEBSITE_DIR="$ROOT_DIR/website"
DOWNLOADS_DIR="$WEBSITE_DIR/downloads"
STAGING_DIR="$ROOT_DIR/dist/sparkle-feed"
GENERATE_APPCAST="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
GENERATE_KEYS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys"

usage() {
  cat <<'EOF'
Usage: ./script/finalize_sparkle_release.sh [path/to/Codex Weekly Reset.app]

Creates the signed Sparkle appcast and website downloads from an already
Developer ID signed, Apple-notarized, and stapled app bundle. It does not
publish, commit, or push anything.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "App bundle not found: $APP_BUNDLE" >&2
  exit 1
fi

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "App Info.plist not found: $INFO_PLIST" >&2
  exit 1
fi

if [[ ! -x "$GENERATE_APPCAST" || ! -x "$GENERATE_KEYS" ]]; then
  echo "Sparkle release tools are missing. Run swift build first." >&2
  exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")"
APP_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
KEYCHAIN_PUBLIC_KEY="$($GENERATE_KEYS --account "$SPARKLE_ACCOUNT" -p)"
NOTES_SOURCE="$ROOT_DIR/docs/release-notes/$APP_VERSION.html"
ARCHIVE_BASENAME="CodexWeeklyReset-v${APP_VERSION}-b${APP_BUILD}"
ARCHIVE_NAME="$ARCHIVE_BASENAME.zip"
NOTES_NAME="$ARCHIVE_BASENAME.html"
ARCHIVE_PATH="$STAGING_DIR/$ARCHIVE_NAME"

if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Unexpected bundle id: $BUNDLE_ID" >&2
  exit 1
fi

if [[ ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
  echo "App build is not numeric: $APP_BUILD" >&2
  exit 1
fi

if [[ "$FEED_URL" != "${PRODUCT_URL}appcast.xml" ]]; then
  echo "Unexpected Sparkle feed URL: $FEED_URL" >&2
  exit 1
fi

if [[ "$APP_PUBLIC_KEY" != "$KEYCHAIN_PUBLIC_KEY" ]]; then
  echo "The app's Sparkle public key does not match Keychain account $SPARKLE_ACCOUNT." >&2
  exit 1
fi

if [[ ! -f "$NOTES_SOURCE" ]]; then
  echo "Release notes not found: $NOTES_SOURCE" >&2
  exit 1
fi

echo "Validating notarized app..."
xcrun stapler validate "$APP_BUNDLE" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null

SIGNING_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
if ! grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<<"$SIGNING_DETAILS"; then
  echo "Unexpected or missing Developer ID team identifier." >&2
  exit 1
fi

GATEKEEPER_DETAILS="$(/usr/sbin/spctl -a -vv "$APP_BUNDLE" 2>&1)"
if ! grep -q 'accepted' <<<"$GATEKEEPER_DETAILS" \
  || ! grep -q 'source=Notarized Developer ID' <<<"$GATEKEEPER_DETAILS"; then
  echo "$GATEKEEPER_DETAILS" >&2
  echo "Gatekeeper did not accept the app as Notarized Developer ID." >&2
  exit 1
fi

mkdir -p "$STAGING_DIR" "$DOWNLOADS_DIR"

if [[ -f "$WEBSITE_DIR/appcast.xml" ]]; then
  cp "$WEBSITE_DIR/appcast.xml" "$STAGING_DIR/appcast.xml"
fi

while IFS= read -r prior_archive; do
  cp "$prior_archive" "$STAGING_DIR/$(basename "$prior_archive")"
done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -name 'CodexWeeklyReset-v*-b*.zip' -print)

while IFS= read -r prior_delta; do
  cp "$prior_delta" "$STAGING_DIR/$(basename "$prior_delta")"
done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f \( -name '*.delta' -o -name '*.delta.*' \) -print)

rm -f "$ARCHIVE_PATH" "$STAGING_DIR/$NOTES_NAME"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"
cp "$NOTES_SOURCE" "$STAGING_DIR/$NOTES_NAME"

echo "Generating signed Sparkle appcast..."
"$GENERATE_APPCAST" \
  --account "$SPARKLE_ACCOUNT" \
  --embed-release-notes \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "$PRODUCT_URL" \
  "$STAGING_DIR" >/dev/null

if [[ ! -f "$STAGING_DIR/appcast.xml" ]]; then
  echo "Sparkle did not generate appcast.xml." >&2
  exit 1
fi

if ! grep -q "<sparkle:version>$APP_BUILD</sparkle:version>" "$STAGING_DIR/appcast.xml" \
  || ! grep -q "$DOWNLOAD_URL_PREFIX$ARCHIVE_NAME" "$STAGING_DIR/appcast.xml"; then
  echo "The generated appcast does not contain build $APP_BUILD and its archive URL." >&2
  exit 1
fi

install -m 644 "$STAGING_DIR/appcast.xml" "$WEBSITE_DIR/appcast.xml"
install -m 644 "$ARCHIVE_PATH" "$DOWNLOADS_DIR/$ARCHIVE_NAME"
install -m 644 "$ARCHIVE_PATH" "$DOWNLOADS_DIR/CodexWeeklyReset.zip"

while IFS= read -r delta_path; do
  install -m 644 "$delta_path" "$DOWNLOADS_DIR/$(basename "$delta_path")"
done < <(find "$STAGING_DIR" -maxdepth 1 -type f \( -name '*.delta' -o -name '*.delta.*' \) -print)

CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
/usr/bin/ditto -x -k "$DOWNLOADS_DIR/CodexWeeklyReset.zip" "$CHECK_DIR"
EXTRACTED_APP="$CHECK_DIR/Codex Weekly Reset.app"
xcrun stapler validate "$EXTRACTED_APP" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP" >/dev/null
EXTRACTED_GATEKEEPER="$(/usr/sbin/spctl -a -vv "$EXTRACTED_APP" 2>&1)"
if ! grep -q 'accepted' <<<"$EXTRACTED_GATEKEEPER" \
  || ! grep -q 'source=Notarized Developer ID' <<<"$EXTRACTED_GATEKEEPER"; then
  echo "$EXTRACTED_GATEKEEPER" >&2
  echo "The extracted website app did not pass Gatekeeper." >&2
  exit 1
fi

echo "Sparkle release $APP_VERSION ($APP_BUILD) is ready locally:"
echo "  website/appcast.xml"
echo "  website/downloads/$ARCHIVE_NAME"
echo "  website/downloads/CodexWeeklyReset.zip"
