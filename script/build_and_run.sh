#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [[ $# -gt 0 ]]; then
  shift
fi
APP_ARGS=("$@")
PRODUCT_NAME="CodexWeeklyReset"
APP_NAME="Codex Weekly Reset"
BUNDLE_ID="com.macintog.codexweeklyreset"
VERSION="0.1.0"
MIN_SYSTEM_VERSION="14.0"
DEVELOPER_ID_APPLICATION_IDENTITY="${CODEX_WEEKLY_RESET_DEVELOPER_ID_APPLICATION_IDENTITY:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PRODUCT_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="AppIcon"
APP_ICONSET_SOURCE="$ROOT_DIR/Resources/$APP_ICON_NAME.iconset"
APP_ICON_PACKER="$ROOT_DIR/script/pack_icns.py"
COUNTER_DIR="${CODEX_WEEKLY_RESET_BUILD_COUNTER_DIR:-$HOME/.codex/build-counters}"
COUNTER_FILE="$COUNTER_DIR/$BUNDLE_ID"

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

mkdir -p "$COUNTER_DIR"
if [[ -f "$COUNTER_FILE" ]]; then
  CURRENT_BUILD="$(tr -cd '0-9' <"$COUNTER_FILE")"
else
  CURRENT_BUILD="0"
fi
CURRENT_BUILD="${CURRENT_BUILD:-0}"
BUILD_NUMBER="$((CURRENT_BUILD + 1))"
printf '%s\n' "$BUILD_NUMBER" >"$COUNTER_FILE"

pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$PRODUCT_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
/usr/bin/python3 "$APP_ICON_PACKER" "$APP_ICONSET_SOURCE" "$APP_RESOURCES/$APP_ICON_NAME.icns"

/usr/bin/python3 - "$INFO_PLIST" "$PRODUCT_NAME" "$APP_NAME" "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER" "$MIN_SYSTEM_VERSION" "$APP_ICON_NAME" <<'PY'
import plistlib
import sys
path, product, app_name, bundle_id, version, build, minimum, icon_name = sys.argv[1:]
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
  "NSPrincipalClass": "NSApplication"
}
with open(path, "wb") as handle:
  plistlib.dump(plist, handle)
PY

case "$MODE" in
  --developer-id|developer-id)
    if [[ -z "$DEVELOPER_ID_APPLICATION_IDENTITY" ]]; then
      echo "CODEX_WEEKLY_RESET_DEVELOPER_ID_APPLICATION_IDENTITY is required for Developer ID signing" >&2
      exit 2
    fi
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
  --debug|debug)
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
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--developer-id] [app args...]" >&2
    exit 2
    ;;
esac
