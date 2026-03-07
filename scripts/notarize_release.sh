#!/usr/bin/env bash
set -euo pipefail

on_err() {
  local exit_code=$?
  echo "Error: command failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  exit "$exit_code"
}
trap on_err ERR

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/scripts/release.env"
SKIP_BUILD=0

usage() {
  cat <<USAGE
Usage: scripts/notarize_release.sh [--skip-build] [--config /path/to/release.env]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || { echo "Error: --config requires value" >&2; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -f "$CONFIG_FILE" ]] || { echo "Error: missing config file: $CONFIG_FILE" >&2; echo "Create from scripts/release.env.example" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || { echo "Error: required variable '$name' is not set in $CONFIG_FILE" >&2; exit 1; }
}

require_var DEV_ID_APP
require_var AC_PROFILE

APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Back Channel}"
APP_EXECUTABLE_NAME="${APP_EXECUTABLE_NAME:-Backchannel}"
APP_NAME="${APP_DISPLAY_NAME}.app"
SAFE_APP_NAME="${APP_DISPLAY_NAME// /-}"
ZIP_NAME="${ZIP_NAME:-${SAFE_APP_NAME}.zip}"
APP_PATH="$ROOT_DIR/dist/$APP_NAME"
ZIP_PATH="$ROOT_DIR/dist/$ZIP_NAME"
BUILD_SCRIPT="$ROOT_DIR/scripts/build_app.sh"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> Building release app"
  "$BUILD_SCRIPT" --mode release
fi

[[ -d "$APP_PATH" ]] || { echo "Error: app bundle not found: $APP_PATH" >&2; exit 1; }

is_macho() {
  file -b "$1" 2>/dev/null | grep -q "Mach-O"
}

audit_portability() {
  echo "==> Running dependency/portability audit"
  local failures=0
  local dep

  while IFS= read -r file_path; do
    is_macho "$file_path" || continue

    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue

      case "$dep" in
        @rpath/*|@loader_path/*|@executable_path/*|/System/Library/*|/usr/lib/*)
          ;;
        /*)
          echo "[audit] non-portable dependency: $file_path -> $dep" >&2
          failures=1
          ;;
        *)
          ;;
      esac
    done < <(otool -L "$file_path" | tail -n +2 | awk '{print $1}')
  done < <(find "$APP_PATH/Contents" -type f -print)

  if [[ "$failures" -ne 0 ]]; then
    echo "Error: portability audit failed. Rebundle dependencies into app resources before notarizing." >&2
    exit 1
  fi
}

audit_portability

MAIN_EXEC="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME"

sign_nested() {
  echo "==> Codesigning nested Mach-O binaries"
  while IFS= read -r nested; do
    [[ -f "$nested" ]] || continue
    is_macho "$nested" || continue
    [[ "$nested" == "$MAIN_EXEC" ]] && continue
    codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$nested"
  done < <(find "$APP_PATH/Contents" -type f -print | sort)
}

sign_nested

echo "==> Codesigning app bundle"
codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$APP_PATH"

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> Creating notarization archive"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent --norsrc "$APP_PATH" "$ZIP_PATH"
[[ -f "$ZIP_PATH" ]] || { echo "Error: zip not created: $ZIP_PATH" >&2; exit 1; }

if zipinfo -1 "$ZIP_PATH" | grep -E '(^__MACOSX/|/\._|^\._)'; then
  echo "Error: zip contains forbidden metadata entries (__MACOSX or AppleDouble)." >&2
  echo "Zip: $ZIP_PATH" >&2
  exit 1
fi

echo "==> Submitting for notarization"
NOTARY_JSON="$(mktemp "${TMPDIR:-/tmp}/notary-result.XXXXXX.json")"
trap 'rm -f "$NOTARY_JSON"' EXIT

xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$AC_PROFILE" \
  --wait \
  --output-format json > "$NOTARY_JSON"

NOTARY_STATUS="$(/usr/bin/plutil -extract status raw "$NOTARY_JSON" 2>/dev/null || true)"
NOTARY_ID="$(/usr/bin/plutil -extract id raw "$NOTARY_JSON" 2>/dev/null || true)"

echo "Notary submission ID: ${NOTARY_ID:-unknown}"
echo "Notary status: ${NOTARY_STATUS:-unknown}"

if [[ "${NOTARY_STATUS:-}" != "Accepted" ]]; then
  echo "Error: notarization failed (status=${NOTARY_STATUS:-unknown})." >&2
  if [[ -n "${NOTARY_ID:-}" ]]; then
    echo "Fetching notarization log..." >&2
    xcrun notarytool log "$NOTARY_ID" --keychain-profile "$AC_PROFILE" || true
  fi
  echo "App: $APP_PATH" >&2
  echo "Zip: $ZIP_PATH" >&2
  exit 1
fi

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "==> Notarized release ready"
echo "App: $APP_PATH"
echo "Zip: $ZIP_PATH"
