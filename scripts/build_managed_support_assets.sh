#!/usr/bin/env bash
set -euo pipefail

on_err() {
  local exit_code=$?
  echo "Error: command failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  exit "$exit_code"
}
trap on_err ERR

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_CONFIG_FILE="$ROOT_DIR/scripts/release.env"
LEGACY_CONFIG_FILE="$ROOT_DIR/.release.env"
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
OUTPUT_DIR="$ROOT_DIR/dist/managed-support"

usage() {
  cat <<USAGE
Usage: scripts/build_managed_support_assets.sh [--config path] [--output-dir path]

Builds separately managed support archives and a manifest for GitHub releases.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "Error: --config requires value" >&2; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { echo "Error: --output-dir requires value" >&2; exit 2; }
      OUTPUT_DIR="$2"
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

if [[ ! -f "$CONFIG_FILE" && -f "$LEGACY_CONFIG_FILE" ]]; then
  echo "Warning: using legacy config file $LEGACY_CONFIG_FILE" >&2
  CONFIG_FILE="$LEGACY_CONFIG_FILE"
fi

[[ -f "$CONFIG_FILE" ]] || { echo "Error: missing config file: $CONFIG_FILE" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || { echo "Error: required variable '$name' is not set in $CONFIG_FILE" >&2; exit 1; }
}

require_var YTDLP_BINARY
require_var DENO_BINARY

is_python_wrapper() {
  local file="$1"
  local first_line
  first_line="$(head -n 1 "$file" || true)"
  [[ "$first_line" == "#!"*python* ]]
}

is_macho_binary() {
  local file="$1"
  file -b "$file" 2>/dev/null | grep -q "Mach-O"
}

portable_binary_audit() {
  local binary="$1"
  local dep

  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    [[ "$dep" == "$binary" ]] && continue
    case "$dep" in
      @rpath/*|@loader_path/*|@executable_path/*|/System/Library/*|/usr/lib/*)
        ;;
      /*)
        echo "Error: non-portable dependency detected: $binary -> $dep" >&2
        exit 1
        ;;
      *)
        ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

yt_dlp_version() {
  "$1" --version | head -n 1 | tr -d '[:space:]'
}

deno_version() {
  "$1" --version | awk 'NR==1 {print $2}' | tr -d '[:space:]'
}

make_component_archive() {
  local component_id="$1"
  local binary_path="$2"
  local version="$3"
  local output_name="$4"
  local stage_root="$5"

  local component_dir="$stage_root/$component_id"
  mkdir -p "$component_dir"
  cp "$binary_path" "$component_dir/$component_id"
  chmod +x "$component_dir/$component_id"

  local zip_path="$OUTPUT_DIR/$output_name"
  rm -f "$zip_path"
  ditto -c -k --keepParent --norsrc "$component_dir" "$zip_path"
  echo "$zip_path"
}

[[ -x "$YTDLP_BINARY" ]] || { echo "Error: YTDLP_BINARY is not executable: $YTDLP_BINARY" >&2; exit 1; }
[[ -x "$DENO_BINARY" ]] || { echo "Error: DENO_BINARY is not executable: $DENO_BINARY" >&2; exit 1; }

if is_python_wrapper "$YTDLP_BINARY"; then
  echo "Error: YTDLP_BINARY points to a Python wrapper script. Use the standalone Mach-O binary." >&2
  exit 1
fi

if ! is_macho_binary "$YTDLP_BINARY"; then
  echo "Error: YTDLP_BINARY is not a standalone Mach-O binary." >&2
  exit 1
fi

if ! is_macho_binary "$DENO_BINARY"; then
  echo "Error: DENO_BINARY is not a standalone Mach-O binary." >&2
  exit 1
fi

portable_binary_audit "$YTDLP_BINARY"
portable_binary_audit "$DENO_BINARY"

YTDLP_VERSION="$(yt_dlp_version "$YTDLP_BINARY")"
DENO_VERSION="$(deno_version "$DENO_BINARY")"
APP_VERSION="${APP_SHORT_VERSION:-0.0.0}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/backchannel-managed-support.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

YTDLP_ASSET_NAME="backchannel-managed-ytdlp-macos-arm64-v${YTDLP_VERSION}.zip"
DENO_ASSET_NAME="backchannel-managed-deno-macos-arm64-v${DENO_VERSION}.zip"

YTDLP_ZIP="$(make_component_archive "yt-dlp" "$YTDLP_BINARY" "$YTDLP_VERSION" "$YTDLP_ASSET_NAME" "$STAGE_DIR")"
DENO_ZIP="$(make_component_archive "deno" "$DENO_BINARY" "$DENO_VERSION" "$DENO_ASSET_NAME" "$STAGE_DIR")"

YTDLP_SHA="$(sha256_file "$YTDLP_ZIP")"
DENO_SHA="$(sha256_file "$DENO_ZIP")"

echo "$YTDLP_SHA  $YTDLP_ZIP" > "${YTDLP_ZIP}.sha256"
echo "$DENO_SHA  $DENO_ZIP" > "${DENO_ZIP}.sha256"

MANIFEST_PATH="$OUTPUT_DIR/backchannel-managed-support.json"
cat > "$MANIFEST_PATH" <<MANIFEST
{
  "schemaVersion": 1,
  "generatedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "appVersion": "${APP_VERSION}",
  "components": [
    {
      "id": "yt-dlp",
      "version": "${YTDLP_VERSION}",
      "assetName": "${YTDLP_ASSET_NAME}",
      "sha256": "${YTDLP_SHA}",
      "executableRelativePath": "yt-dlp/yt-dlp",
      "minimumAppVersion": "${APP_VERSION}"
    },
    {
      "id": "deno",
      "version": "${DENO_VERSION}",
      "assetName": "${DENO_ASSET_NAME}",
      "sha256": "${DENO_SHA}",
      "executableRelativePath": "deno/deno",
      "minimumAppVersion": "${APP_VERSION}"
    }
  ]
}
MANIFEST

echo "$(sha256_file "$MANIFEST_PATH")  $MANIFEST_PATH" > "${MANIFEST_PATH}.sha256"

echo "Managed support assets ready:"
echo "  $YTDLP_ZIP"
echo "  ${YTDLP_ZIP}.sha256"
echo "  $DENO_ZIP"
echo "  ${DENO_ZIP}.sha256"
echo "  $MANIFEST_PATH"
echo "  ${MANIFEST_PATH}.sha256"
