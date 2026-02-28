#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${1:-$ROOT_DIR/.release.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: release config not found: $CONFIG_FILE" >&2
  echo "Create it from: $ROOT_DIR/.release.env.example" >&2
  exit 1
fi

set -a
source "$CONFIG_FILE"
set +a

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Error: missing required config var: $name" >&2
    exit 1
  fi
}

require_var SIGNING_IDENTITY
require_var TEAM_ID
require_var NOTARY_KEYCHAIN_PROFILE
require_var YTDLP_BINARY

APP_PATH="${APP_PATH:-$ROOT_DIR/dist/Back Channel.app}"
if [[ -n "${APP_SHORT_VERSION:-}" ]]; then
  ZIP_PATH="$ROOT_DIR/dist/Back-Channel-${APP_SHORT_VERSION}.zip"
else
  ZIP_PATH="$ROOT_DIR/dist/Back-Channel.zip"
fi

echo "==> Building package"
env \
  YTDLP_BINARY="$YTDLP_BINARY" \
  FFMPEG_BINARY="${FFMPEG_BINARY:-}" \
  FFPROBE_BINARY="${FFPROBE_BINARY:-}" \
  DENO_BINARY="${DENO_BINARY:-}" \
  APP_SHORT_VERSION="${APP_SHORT_VERSION:-}" \
  APP_BUILD_VERSION="${APP_BUILD_VERSION:-}" \
  "$ROOT_DIR/scripts/package_app.sh"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: app bundle not found: $APP_PATH" >&2
  exit 1
fi

echo "==> Signing embedded binaries (Mach-O) with hardened runtime + timestamp"
find "$APP_PATH" -type f | while read -r f; do
  if file "$f" | grep -q "Mach-O"; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$f"
  fi
done

echo "==> Signing app bundle"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH"

if [[ "${STORE_NOTARY_CREDENTIALS:-0}" == "1" ]]; then
  require_var APPLE_ID
  require_var APP_SPECIFIC_PASSWORD
  echo "==> Storing notary credentials in keychain profile: $NOTARY_KEYCHAIN_PROFILE"
  xcrun notarytool store-credentials "$NOTARY_KEYCHAIN_PROFILE" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD"
fi

echo "==> Creating notarization archive"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting for notarization (wait)"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
  --wait

echo "==> Stapling ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Release build ready"
echo "App: $APP_PATH"
echo "Zip: $ZIP_PATH"
