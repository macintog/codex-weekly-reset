#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [[ $# -gt 0 ]]; then
  shift
fi
APP_ARGS=("$@")

usage() {
  echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify|--developer-id] [app args...]"
}

case "$MODE" in
  -h|--help|help)
    usage
    exit 0
    ;;
  run|--build|build|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--developer-id|developer-id)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

PRODUCT_NAME="CodexWeeklyReset"
APP_NAME="Codex Weekly Reset"
BUNDLE_ID="com.macintog.codexweeklyreset"
VERSION="0.1.6"
MIN_SYSTEM_VERSION="14.0"
SPARKLE_FEED_URL="https://macintog.github.io/codex-weekly-reset/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="bER9pCOTM3mGPhd0hAgk7wfm+ZmHfKULAJcObpdNkBI=" # gitleaks:allow - public verification key
APPLE_TEAM_ID="${CODEX_WEEKLY_RESET_APPLE_TEAM_ID:-A9FAXYYTNZ}"
DEVELOPER_ID_APPLICATION_IDENTITY="${CODEX_WEEKLY_RESET_DEVELOPER_ID_APPLICATION_IDENTITY:-Developer ID Application: R&D Solutions LLC (${APPLE_TEAM_ID})}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_BINARY="$APP_MACOS/$PRODUCT_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="AppIcon"
APP_ICONSET_SOURCE="$ROOT_DIR/Resources/$APP_ICON_NAME.iconset"
APP_ICON_PACKER="$ROOT_DIR/script/pack_icns.py"
BUILD_PROVENANCE_HELPER="$ROOT_DIR/script/build_provenance.py"
COUNTER_DIR="${CODEX_WEEKLY_RESET_BUILD_COUNTER_DIR:-$HOME/.codex/build-counters}"
LEGACY_BUNDLE_ID="com.ryand.codexweeklyreset"

normalize_app_args() {
  local normalized=()
  local index=0
  while [[ $index -lt ${#APP_ARGS[@]} ]]; do
    local arg="${APP_ARGS[$index]}"
    if [[ "$arg" == "--fixture" || "$arg" == "--codex-path" ]]; then
      normalized+=("$arg")
      index=$((index + 1))
      if [[ $index -lt ${#APP_ARGS[@]} ]]; then
        local value="${APP_ARGS[$index]}"
        if [[ "$value" == /* ]]; then
          normalized+=("$value")
        else
          normalized+=("$ROOT_DIR/$value")
        fi
      fi
    else
      normalized+=("$arg")
    fi
    index=$((index + 1))
  done
  if [[ ${#normalized[@]} -eq 0 ]]; then
    APP_ARGS=()
  else
    APP_ARGS=("${normalized[@]}")
  fi
}

normalize_app_args

BUILD_NUMBER="$(/usr/bin/python3 "$BUILD_PROVENANCE_HELPER" counter \
  --directory "$COUNTER_DIR" \
  --bundle-id "$BUNDLE_ID" \
  --legacy-id "$LEGACY_BUNDLE_ID")"

PROVENANCE_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/codex-weekly-reset-provenance.XXXXXX")"
trap 'rm -f "$PROVENANCE_SNAPSHOT"' EXIT
/usr/bin/python3 "$BUILD_PROVENANCE_HELPER" snapshot --root "$ROOT_DIR" --output "$PROVENANCE_SNAPSHOT"

cd "$ROOT_DIR"
swift build
BUILD_BIN_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$PRODUCT_NAME"
SPARKLE_FRAMEWORK="$BUILD_BIN_DIR/Sparkle.framework"
SPARKLE_NOTICES="$ROOT_DIR/Resources/ThirdPartyNotices/Sparkle-LICENSE.txt"
SPARKLE_DISTRIBUTION_NOTICES="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/LICENSE"

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle.framework was not emitted beside the SwiftPM executable: $SPARKLE_FRAMEWORK" >&2
  exit 1
fi

if ! cmp -s "$SPARKLE_NOTICES" "$SPARKLE_DISTRIBUTION_NOTICES"; then
  echo "Sparkle notices must match the resolved dependency before packaging." >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"
/usr/bin/python3 "$APP_ICON_PACKER" "$APP_ICONSET_SOURCE" "$APP_RESOURCES/$APP_ICON_NAME.icns"
cp "$PROVENANCE_SNAPSHOT" "$APP_RESOURCES/BuildProvenance.json"
cp "$SPARKLE_NOTICES" "$APP_RESOURCES/Sparkle-LICENSE.txt"

/usr/bin/python3 - "$INFO_PLIST" "$PRODUCT_NAME" "$APP_NAME" "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER" "$MIN_SYSTEM_VERSION" "$APP_ICON_NAME" "$SPARKLE_FEED_URL" "$SPARKLE_PUBLIC_ED_KEY" <<'PY'
import plistlib
import sys
path, product, app_name, bundle_id, version, build, minimum, icon_name, sparkle_feed_url, sparkle_public_key = sys.argv[1:]
plist = {
  "CFBundleExecutable": product,
  "CFBundleIconFile": icon_name,
  "CFBundleIdentifier": bundle_id,
  "CFBundleName": app_name,
  "CFBundleDisplayName": app_name,
  "CFBundlePackageType": "APPL",
  "CFBundleShortVersionString": version,
  "CFBundleVersion": build,
  "LSMinimumSystemVersion": minimum,
  "LSUIElement": True,
  "NSPrincipalClass": "NSApplication",
  "SUAllowsAutomaticUpdates": True,
  "SUAutomaticallyUpdate": True,
  "SUEnableAutomaticChecks": True,
  "SUFeedURL": sparkle_feed_url,
  "SUPublicEDKey": sparkle_public_key,
  "SURequireSignedFeed": True,
  "SUVerifyUpdateBeforeExtraction": True
}
with open(path, "wb") as handle:
  plistlib.dump(plist, handle)
PY

/usr/bin/python3 "$BUILD_PROVENANCE_HELPER" verify --root "$ROOT_DIR" --snapshot "$PROVENANCE_SNAPSHOT"

sign_artifact() {
  local artifact_path="$1"

  case "$MODE" in
    --developer-id|developer-id)
      /usr/bin/codesign \
        --force \
        --sign "$DEVELOPER_ID_APPLICATION_IDENTITY" \
        --timestamp \
        --options runtime \
        --preserve-metadata=identifier,requirements,flags \
        "$artifact_path" >/dev/null
      ;;
    *)
      /usr/bin/codesign \
        --force \
        --sign - \
        --preserve-metadata=identifier,requirements,flags \
        "$artifact_path" >/dev/null
      ;;
  esac
}

SPARKLE_NESTED_PATHS=(
  "$APP_FRAMEWORKS/Sparkle.framework/Versions/B/Autoupdate"
  "$APP_FRAMEWORKS/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
  "$APP_FRAMEWORKS/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
  "$APP_FRAMEWORKS/Sparkle.framework/Versions/B/Updater.app"
  "$APP_FRAMEWORKS/Sparkle.framework"
)

for nested_path in "${SPARKLE_NESTED_PATHS[@]}"; do
  if [[ -e "$nested_path" ]]; then
    sign_artifact "$nested_path"
  fi
done

case "$MODE" in
  --developer-id|developer-id)
    /usr/bin/codesign \
      --force \
      --sign "$DEVELOPER_ID_APPLICATION_IDENTITY" \
      --identifier "$BUNDLE_ID" \
      --timestamp \
      --options runtime \
      "$APP_BUNDLE" >/dev/null
    ;;
  *)
    /usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE" >/dev/null
    ;;
esac

open_app() {
  pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true
  if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
    /usr/bin/open -n "$APP_BUNDLE" --args "${APP_ARGS[@]}"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --build|build)
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null
    echo "$APP_NAME build $BUILD_NUMBER is ready for local testing: $APP_BUNDLE"
    ;;
  --debug|debug)
    pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PRODUCT_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$PRODUCT_NAME" >/dev/null
    echo "$APP_NAME build $BUILD_NUMBER is running"
    ;;
  --developer-id|developer-id)
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null
    echo "$APP_NAME build $BUILD_NUMBER is signed with Developer ID"
    ;;
esac
