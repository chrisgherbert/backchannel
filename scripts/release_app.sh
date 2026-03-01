#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${1:-$ROOT_DIR/.release.env}"
YTDLP_ENTITLEMENTS="$ROOT_DIR/scripts/entitlements.ytdlp.plist"

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

cleanup() {
  if [[ -n "${NOTARY_RESULT_FILE:-}" ]] && [[ -f "$NOTARY_RESULT_FILE" ]]; then
    rm -f "$NOTARY_RESULT_FILE"
  fi
}
trap cleanup EXIT

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
  DENO_REQUIRED="1" \
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
    if [[ "$f" == */Contents/Resources/bin/yt-dlp ]] || [[ "$f" == */Contents/Resources/bin/ffmpeg ]] || [[ "$f" == */Contents/Resources/bin/ffprobe ]]; then
      codesign --force --options runtime --timestamp --entitlements "$YTDLP_ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$f"
    else
      codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$f"
    fi
  fi
done

echo "==> Signing app bundle"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

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
if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Error: notarization archive was not created: $ZIP_PATH" >&2
  exit 1
fi

echo "==> Submitting for notarization (wait)"
NOTARY_RESULT_FILE="$(mktemp "${TMPDIR:-/tmp}/backchannel-notary.XXXXXX.json")"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
  --wait \
  --output-format json > "$NOTARY_RESULT_FILE"

NOTARY_STATUS="$(/usr/bin/plutil -extract status raw "$NOTARY_RESULT_FILE" 2>/dev/null || true)"
NOTARY_ID="$(/usr/bin/plutil -extract id raw "$NOTARY_RESULT_FILE" 2>/dev/null || true)"
echo "Notary submission ID: ${NOTARY_ID:-unknown}"
echo "Notary status: ${NOTARY_STATUS:-unknown}"

if [[ "${NOTARY_STATUS:-}" != "Accepted" ]]; then
  echo "Error: notarization did not return Accepted." >&2
  if [[ -n "${NOTARY_ID:-}" ]]; then
    echo "Fetching notarization log for submission ${NOTARY_ID}..." >&2
    xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" || true
  fi
  exit 1
fi

echo "==> Stapling ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Final Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "==> Release build ready"
echo "App: $APP_PATH"
echo "Zip: $ZIP_PATH"
