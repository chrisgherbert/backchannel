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
DEFAULT_PYTHON_STANDALONE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260320/cpython-3.13.12+20260320-aarch64-apple-darwin-install_only_stripped.tar.gz"
DEFAULT_YTDLP_PACKAGE_SPEC="yt-dlp[default]"
DEFAULT_YTDLP_EXTRA_PACKAGES="yt-dlp-ejs streamlink"

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

ENV_APP_SHORT_VERSION="${APP_SHORT_VERSION:-}"
ENV_DENO_BINARY="${DENO_BINARY:-}"
ENV_PYTHON_STANDALONE_URL="${PYTHON_STANDALONE_URL:-}"
ENV_PYTHON_STANDALONE_ARCHIVE="${PYTHON_STANDALONE_ARCHIVE:-}"
ENV_YTDLP_PACKAGE_SPEC="${YTDLP_PACKAGE_SPEC:-}"
ENV_YTDLP_EXTRA_PACKAGES="${YTDLP_EXTRA_PACKAGES:-}"

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

[[ -n "$ENV_APP_SHORT_VERSION" ]] && APP_SHORT_VERSION="$ENV_APP_SHORT_VERSION"
[[ -n "$ENV_DENO_BINARY" ]] && DENO_BINARY="$ENV_DENO_BINARY"
[[ -n "$ENV_PYTHON_STANDALONE_URL" ]] && PYTHON_STANDALONE_URL="$ENV_PYTHON_STANDALONE_URL"
[[ -n "$ENV_PYTHON_STANDALONE_ARCHIVE" ]] && PYTHON_STANDALONE_ARCHIVE="$ENV_PYTHON_STANDALONE_ARCHIVE"
[[ -n "$ENV_YTDLP_PACKAGE_SPEC" ]] && YTDLP_PACKAGE_SPEC="$ENV_YTDLP_PACKAGE_SPEC"
[[ -n "$ENV_YTDLP_EXTRA_PACKAGES" ]] && YTDLP_EXTRA_PACKAGES="$ENV_YTDLP_EXTRA_PACKAGES"

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || { echo "Error: required variable '$name' is not set in $CONFIG_FILE" >&2; exit 1; }
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

system_cert_bundle() {
  local candidate
  for candidate in /etc/ssl/cert.pem /private/etc/ssl/cert.pem; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

python_runtime_version() {
  "$1" -V 2>&1 | awk '{print $2}' | tr -d '[:space:]'
}

ytdlp_version() {
  "$1" -m yt_dlp --version | head -n 1 | tr -d '[:space:]'
}

deno_version() {
  "$1" --version | awk 'NR==1 {print $2}' | tr -d '[:space:]'
}

download_file() {
  local url="$1"
  local destination="$2"
  curl -L --fail --silent --show-error -o "$destination" "$url"
}

prepare_python_runtime() {
  local archive_path="$1"
  local destination_root="$2"

  rm -rf "$destination_root"
  mkdir -p "$destination_root"
  tar -xzf "$archive_path" -C "$destination_root"

  local python_bin="$destination_root/python/bin/python3"
  [[ -x "$python_bin" ]] || {
    echo "Error: portable Python runtime did not contain python/bin/python3" >&2
    exit 1
  }

  portable_binary_audit "$python_bin"

  local cert_bundle=""
  cert_bundle="$(system_cert_bundle || true)"
  if [[ -n "$cert_bundle" ]]; then
    export SSL_CERT_FILE="$cert_bundle"
    export REQUESTS_CA_BUNDLE="$cert_bundle"
    export CURL_CA_BUNDLE="$cert_bundle"
  fi

  "$python_bin" -m pip install \
    --disable-pip-version-check \
    --no-python-version-warning \
    --no-cache-dir \
    --upgrade \
    "${YTDLP_PACKAGE_SPEC:-$DEFAULT_YTDLP_PACKAGE_SPEC}" \
    ${YTDLP_EXTRA_PACKAGES:-$DEFAULT_YTDLP_EXTRA_PACKAGES}

  "$python_bin" -m yt_dlp --version >/dev/null
}

make_component_archive_from_directory() {
  local component_id="$1"
  local source_dir="$2"
  local output_name="$3"
  local stage_root="$4"

  local component_dir="$stage_root/$component_id"
  rm -rf "$component_dir"
  mkdir -p "$component_dir"
  ditto "$source_dir" "$component_dir/$(basename "$source_dir")"

  local zip_path="$OUTPUT_DIR/$output_name"
  rm -f "$zip_path"
  ditto -c -k --keepParent --norsrc "$component_dir" "$zip_path"
  echo "$zip_path"
}

make_component_archive_from_binary() {
  local component_id="$1"
  local binary_path="$2"
  local output_name="$3"
  local stage_root="$4"

  local component_dir="$stage_root/$component_id"
  rm -rf "$component_dir"
  mkdir -p "$component_dir"
  cp "$binary_path" "$component_dir/$component_id"
  chmod +x "$component_dir/$component_id"

  local zip_path="$OUTPUT_DIR/$output_name"
  rm -f "$zip_path"
  ditto -c -k --keepParent --norsrc "$component_dir" "$zip_path"
  echo "$zip_path"
}

require_var DENO_BINARY

[[ -x "$DENO_BINARY" ]] || { echo "Error: DENO_BINARY is not executable: $DENO_BINARY" >&2; exit 1; }
if ! is_macho_binary "$DENO_BINARY"; then
  echo "Error: DENO_BINARY is not a standalone Mach-O binary." >&2
  exit 1
fi
portable_binary_audit "$DENO_BINARY"

PYTHON_ARCHIVE_URL="${PYTHON_STANDALONE_URL:-$DEFAULT_PYTHON_STANDALONE_URL}"
PYTHON_ARCHIVE_PATH="${PYTHON_STANDALONE_ARCHIVE:-}"
YTDLP_PACKAGE_SPEC="${YTDLP_PACKAGE_SPEC:-$DEFAULT_YTDLP_PACKAGE_SPEC}"
APP_VERSION="${APP_SHORT_VERSION:-0.0.0}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/backchannel-managed-support.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

if [[ -n "$PYTHON_ARCHIVE_PATH" ]]; then
  [[ -f "$PYTHON_ARCHIVE_PATH" ]] || { echo "Error: PYTHON_STANDALONE_ARCHIVE not found: $PYTHON_ARCHIVE_PATH" >&2; exit 1; }
  PYTHON_ARCHIVE="$PYTHON_ARCHIVE_PATH"
else
  PYTHON_ARCHIVE="$STAGE_DIR/python-build-standalone.tar.gz"
  echo "Fetching portable Python runtime..."
  download_file "$PYTHON_ARCHIVE_URL" "$PYTHON_ARCHIVE"
fi

PYTHON_RUNTIME_DIR="$STAGE_DIR/python-runtime"
echo "Preparing managed Python runtime..."
prepare_python_runtime "$PYTHON_ARCHIVE" "$PYTHON_RUNTIME_DIR"

PYTHON_BIN="$PYTHON_RUNTIME_DIR/python/bin/python3"
PYTHON_VERSION="$(python_runtime_version "$PYTHON_BIN")"
PYTHON_VERSION_LABEL="Python ${PYTHON_VERSION}"
YTDLP_VERSION="$(ytdlp_version "$PYTHON_BIN")"
DENO_VERSION="$(deno_version "$DENO_BINARY")"

YTDLP_COMPONENT_VERSION="py${PYTHON_VERSION}+yt${YTDLP_VERSION}"
YTDLP_ASSET_NAME="backchannel-managed-ytdlp-runtime-macos-arm64-py${PYTHON_VERSION}-yt${YTDLP_VERSION}.zip"
DENO_ASSET_NAME="backchannel-managed-deno-macos-arm64-v${DENO_VERSION}.zip"

YTDLP_ZIP="$(make_component_archive_from_directory "yt-dlp" "$PYTHON_RUNTIME_DIR/python" "$YTDLP_ASSET_NAME" "$STAGE_DIR")"
DENO_ZIP="$(make_component_archive_from_binary "deno" "$DENO_BINARY" "$DENO_ASSET_NAME" "$STAGE_DIR")"

YTDLP_SHA="$(sha256_file "$YTDLP_ZIP")"
DENO_SHA="$(sha256_file "$DENO_ZIP")"

echo "$YTDLP_SHA  $YTDLP_ZIP" > "${YTDLP_ZIP}.sha256"
echo "$DENO_SHA  $DENO_ZIP" > "${DENO_ZIP}.sha256"

MANIFEST_PATH="$OUTPUT_DIR/backchannel-managed-support.json"
cat > "$MANIFEST_PATH" <<MANIFEST
{
  "schemaVersion": 2,
  "generatedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "appVersion": "${APP_VERSION}",
  "components": [
    {
      "id": "yt-dlp",
      "version": "${YTDLP_COMPONENT_VERSION}",
      "assetName": "${YTDLP_ASSET_NAME}",
      "sha256": "${YTDLP_SHA}",
      "executableRelativePath": "yt-dlp/python/bin/python3",
      "argumentsPrefix": ["-m", "yt_dlp"],
      "toolVersion": "${YTDLP_VERSION}",
      "runtimeVersion": "${PYTHON_VERSION_LABEL}",
      "minimumAppVersion": "${APP_VERSION}"
    },
    {
      "id": "deno",
      "version": "${DENO_VERSION}",
      "assetName": "${DENO_ASSET_NAME}",
      "sha256": "${DENO_SHA}",
      "executableRelativePath": "deno/deno",
      "argumentsPrefix": [],
      "toolVersion": "${DENO_VERSION}",
      "runtimeVersion": null,
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
