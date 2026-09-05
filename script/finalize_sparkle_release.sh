#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/Codex Weekly Reset.app"
EXPECTED_BUNDLE_ID="com.macintog.codexweeklyreset"
EXPECTED_TEAM_ID="${CODEX_WEEKLY_RESET_APPLE_TEAM_ID:-A9FAXYYTNZ}"
SPARKLE_ACCOUNT="${CODEX_WEEKLY_RESET_SPARKLE_ACCOUNT:-ed25519}"
DOWNLOAD_URL_PREFIX="https://macintog.github.io/codex-weekly-reset/downloads/"
PRODUCT_URL="https://macintog.github.io/codex-weekly-reset/"
WEBSITE_DIR="$ROOT_DIR/website"
TOOLS_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
REQUESTED_STAGING_DIR=""

usage() {
  cat <<'EOF'
Usage: ./script/finalize_sparkle_release.sh [options] [path/to/Codex Weekly Reset.app]

Options:
  --website-dir PATH  Website tree to stage and update (default: root/website)
  --tools-dir PATH    Directory containing Sparkle release tools
  --staging-dir PATH  New path to retain as release staging evidence
  -h, --help          Show this help

Creates the signed Sparkle appcast and website downloads from an already
Developer ID signed, Apple-notarized, and stapled app bundle. It does not
publish, commit, or push anything.
EOF
}

positional_count=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --website-dir|--tools-dir|--staging-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; usage >&2; exit 2; }
      option="$1"; value="$2"; shift 2
      case "$option" in
        --website-dir) WEBSITE_DIR="$value" ;;
        --tools-dir) TOOLS_DIR="$value" ;;
        --staging-dir) REQUESTED_STAGING_DIR="$value" ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      positional_count=$((positional_count + 1))
      [[ $positional_count -le 1 ]] || { usage >&2; exit 2; }
      APP_BUNDLE="$1"; shift
      ;;
  esac
done

GENERATE_APPCAST="$TOOLS_DIR/generate_appcast"
GENERATE_KEYS="$TOOLS_DIR/generate_keys"
SIGN_UPDATE="$TOOLS_DIR/sign_update"
DOWNLOADS_DIR="$WEBSITE_DIR/downloads"

[[ -d "$APP_BUNDLE" ]] || { echo "App bundle not found: $APP_BUNDLE" >&2; exit 1; }
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || { echo "App Info.plist not found: $INFO_PLIST" >&2; exit 1; }
if [[ ! -x "$GENERATE_APPCAST" || ! -x "$GENERATE_KEYS" || ! -x "$SIGN_UPDATE" ]]; then
  echo "Sparkle release tools are missing from: $TOOLS_DIR" >&2
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

[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || { echo "Unexpected bundle id: $BUNDLE_ID" >&2; exit 1; }
[[ "$APP_BUILD" =~ ^[0-9]+$ ]] || { echo "App build is not numeric: $APP_BUILD" >&2; exit 1; }
[[ "$FEED_URL" == "${PRODUCT_URL}appcast.xml" ]] || { echo "Unexpected Sparkle feed URL: $FEED_URL" >&2; exit 1; }
[[ "$APP_PUBLIC_KEY" == "$KEYCHAIN_PUBLIC_KEY" ]] || { echo "The app's Sparkle public key does not match Keychain account $SPARKLE_ACCOUNT." >&2; exit 1; }
[[ -f "$NOTES_SOURCE" ]] || { echo "Release notes not found: $NOTES_SOURCE" >&2; exit 1; }

echo "Validating notarized app..."
xcrun stapler validate "$APP_BUNDLE" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null
SIGNING_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<<"$SIGNING_DETAILS" || { echo "Unexpected or missing Developer ID team identifier." >&2; exit 1; }
GATEKEEPER_DETAILS="$(/usr/sbin/spctl -a -vv "$APP_BUNDLE" 2>&1)"
if ! grep -q 'accepted' <<<"$GATEKEEPER_DETAILS" || ! grep -q 'source=Notarized Developer ID' <<<"$GATEKEEPER_DETAILS"; then
  echo "$GATEKEEPER_DETAILS" >&2
  echo "Gatekeeper did not accept the app as Notarized Developer ID." >&2
  exit 1
fi

cleanup_owned_staging=false
if [[ -n "$REQUESTED_STAGING_DIR" ]]; then
  [[ ! -e "$REQUESTED_STAGING_DIR" ]] || { echo "Staging path already exists; refusing stale staging reuse: $REQUESTED_STAGING_DIR" >&2; exit 1; }
  STAGING_DIR="$REQUESTED_STAGING_DIR"
  mkdir -p "$STAGING_DIR"
else
  mkdir -p "$ROOT_DIR/dist"
  STAGING_DIR="$(mktemp -d "$ROOT_DIR/dist/sparkle-feed.XXXXXX")"
  cleanup_owned_staging=true
fi
cleanup() {
  if [[ "$cleanup_owned_staging" == true ]]; then rm -rf "$STAGING_DIR"; fi
}
trap cleanup EXIT

STAGED_WEBSITE="$STAGING_DIR/website"
FEED_WORK="$STAGING_DIR/feed-work"
CHECK_DIR="$STAGING_DIR/extracted"
mkdir -p "$STAGED_WEBSITE" "$FEED_WORK" "$CHECK_DIR"
if [[ -d "$WEBSITE_DIR" ]]; then cp -R "$WEBSITE_DIR/." "$STAGED_WEBSITE/"; fi
mkdir -p "$STAGED_WEBSITE/downloads"
PRIOR_FEED="$STAGING_DIR/prior-appcast.xml"
if [[ -f "$STAGED_WEBSITE/appcast.xml" ]]; then
  cp "$STAGED_WEBSITE/appcast.xml" "$PRIOR_FEED"
  cp "$PRIOR_FEED" "$FEED_WORK/appcast.xml"
  python3 "$ROOT_DIR/script/release_feed.py" \
    --prior-feed "$PRIOR_FEED" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --recreate-retained-notes "$FEED_WORK"
fi
while IFS= read -r prior_asset; do
  cp "$prior_asset" "$FEED_WORK/$(basename "$prior_asset")"
done < <(find "$STAGED_WEBSITE/downloads" -maxdepth 1 -type f \( -name 'CodexWeeklyReset-v*-b*.zip' -o -name '*.delta' -o -name '*.delta.*' \) -print)

CANDIDATE_ARCHIVE="$STAGING_DIR/$ARCHIVE_NAME"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$CANDIDATE_ARCHIVE"
cp "$NOTES_SOURCE" "$FEED_WORK/$NOTES_NAME"
existing_build=false
EXISTING_ARCHIVE="$STAGED_WEBSITE/downloads/$ARCHIVE_NAME"
if [[ -f "$EXISTING_ARCHIVE" ]]; then
  if ! cmp -s "$CANDIDATE_ARCHIVE" "$EXISTING_ARCHIVE"; then
    echo "Build $APP_BUILD already has a different versioned archive: $EXISTING_ARCHIVE" >&2
    echo "Refusing to overwrite an existing Sparkle build. A re-zip of the same signed app can differ; use the recorded ready release receipt instead." >&2
    exit 1
  fi
  existing_build=true
  cp "$EXISTING_ARCHIVE" "$FEED_WORK/$ARCHIVE_NAME"
else
  cp "$CANDIDATE_ARCHIVE" "$FEED_WORK/$ARCHIVE_NAME"
fi

if [[ "$existing_build" == false ]]; then
  echo "Generating signed Sparkle appcast..."
  "$GENERATE_APPCAST" --account "$SPARKLE_ACCOUNT" --embed-release-notes \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" --link "$PRODUCT_URL" "$FEED_WORK" >/dev/null
fi
[[ -f "$FEED_WORK/appcast.xml" ]] || { echo "Sparkle did not generate appcast.xml." >&2; exit 1; }
cp "$FEED_WORK/appcast.xml" "$STAGED_WEBSITE/appcast.xml"
while IFS= read -r generated_asset; do
  cp "$generated_asset" "$STAGED_WEBSITE/downloads/$(basename "$generated_asset")"
done < <(find "$FEED_WORK" -maxdepth 1 -type f \( -name 'CodexWeeklyReset-v*-b*.zip' -o -name '*.delta' -o -name '*.delta.*' \) -print)
cp "$STAGED_WEBSITE/downloads/$ARCHIVE_NAME" "$STAGED_WEBSITE/downloads/CodexWeeklyReset.zip"

validator_args=(--feed "$STAGED_WEBSITE/appcast.xml" --assets-dir "$STAGED_WEBSITE/downloads"
  --expected-build "$APP_BUILD" --expected-version "$APP_VERSION" --expected-archive "$ARCHIVE_NAME"
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" --expected-notes "$NOTES_SOURCE"
  --print-enclosure-signatures)
if [[ -f "$PRIOR_FEED" ]]; then validator_args+=(--prior-feed "$PRIOR_FEED"); fi
if [[ "$existing_build" == true ]]; then validator_args+=(--allow-existing-build); fi
ENCLOSURE_SIGNATURES="$(python3 "$ROOT_DIR/script/release_feed.py" "${validator_args[@]}")"
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$STAGED_WEBSITE/appcast.xml" >/dev/null
while IFS=$'\t' read -r enclosure_name enclosure_signature; do
  "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify \
    "$STAGED_WEBSITE/downloads/$enclosure_name" "$enclosure_signature" >/dev/null
done <<<"$ENCLOSURE_SIGNATURES"

/usr/bin/ditto -x -k "$STAGED_WEBSITE/downloads/CodexWeeklyReset.zip" "$CHECK_DIR"
EXTRACTED_APP="$CHECK_DIR/Codex Weekly Reset.app"
EXTRACTED_INFO_PLIST="$EXTRACTED_APP/Contents/Info.plist"
[[ -f "$EXTRACTED_INFO_PLIST" ]] || { echo "Extracted app Info.plist is missing." >&2; exit 1; }
EXTRACTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXTRACTED_INFO_PLIST")"
EXTRACTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXTRACTED_INFO_PLIST")"
EXTRACTED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXTRACTED_INFO_PLIST")"
if [[ "$EXTRACTED_BUILD" != "$APP_BUILD" || "$EXTRACTED_VERSION" != "$APP_VERSION" || "$EXTRACTED_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Extracted app identity does not match release $APP_VERSION ($APP_BUILD), $EXPECTED_BUNDLE_ID." >&2
  exit 1
fi
xcrun stapler validate "$EXTRACTED_APP" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP" >/dev/null
EXTRACTED_GATEKEEPER="$(/usr/sbin/spctl -a -vv "$EXTRACTED_APP" 2>&1)"
if ! grep -q 'accepted' <<<"$EXTRACTED_GATEKEEPER" || ! grep -q 'source=Notarized Developer ID' <<<"$EXTRACTED_GATEKEEPER"; then
  echo "$EXTRACTED_GATEKEEPER" >&2
  echo "The extracted staged website app did not pass Gatekeeper." >&2
  exit 1
fi

# The destination remains untouched until every release gate above passes.
mkdir -p "$DOWNLOADS_DIR"
install -m 644 "$STAGED_WEBSITE/downloads/$ARCHIVE_NAME" "$DOWNLOADS_DIR/$ARCHIVE_NAME"
install -m 644 "$STAGED_WEBSITE/downloads/CodexWeeklyReset.zip" "$DOWNLOADS_DIR/CodexWeeklyReset.zip"
while IFS= read -r delta_path; do
  install -m 644 "$delta_path" "$DOWNLOADS_DIR/$(basename "$delta_path")"
done < <(find "$STAGED_WEBSITE/downloads" -maxdepth 1 -type f \( -name '*.delta' -o -name '*.delta.*' \) -print)
install -m 644 "$STAGED_WEBSITE/appcast.xml" "$WEBSITE_DIR/appcast.xml"

echo "Sparkle release $APP_VERSION ($APP_BUILD) is ready locally:"
echo "  $WEBSITE_DIR/appcast.xml"
echo "  $DOWNLOADS_DIR/$ARCHIVE_NAME"
echo "  $DOWNLOADS_DIR/CodexWeeklyReset.zip"
