#!/usr/bin/env bash
set -euo pipefail

on_err() {
  local exit_code=$?
  echo "Error: command failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  exit "$exit_code"
}
trap on_err ERR

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/build_managed_support_assets.sh"
DEFAULT_CONFIG_FILE="$ROOT_DIR/scripts/release.env"
LEGACY_CONFIG_FILE="$ROOT_DIR/.release.env"
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
NOTES_FILE=""
SKIP_BUILD=0

usage() {
  cat <<USAGE
Usage: scripts/publish_managed_support.sh [--config path] [--notes-file path] [--skip-build]

Builds and publishes managed support assets to the dedicated GitHub release channel.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "Error: --config requires value" >&2; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --notes-file)
      [[ $# -ge 2 ]] || { echo "Error: --notes-file requires value" >&2; exit 2; }
      NOTES_FILE="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
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

if [[ -f "$CONFIG_FILE" ]]; then
  ENV_APP_SHORT_VERSION="${APP_SHORT_VERSION:-}"
  ENV_DENO_BINARY="${DENO_BINARY:-}"
  ENV_PYTHON_STANDALONE_URL="${PYTHON_STANDALONE_URL:-}"
  ENV_PYTHON_STANDALONE_ARCHIVE="${PYTHON_STANDALONE_ARCHIVE:-}"
  ENV_YTDLP_PACKAGE_SPEC="${YTDLP_PACKAGE_SPEC:-}"
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
  [[ -n "$ENV_APP_SHORT_VERSION" ]] && APP_SHORT_VERSION="$ENV_APP_SHORT_VERSION"
  [[ -n "$ENV_DENO_BINARY" ]] && DENO_BINARY="$ENV_DENO_BINARY"
  [[ -n "$ENV_PYTHON_STANDALONE_URL" ]] && PYTHON_STANDALONE_URL="$ENV_PYTHON_STANDALONE_URL"
  [[ -n "$ENV_PYTHON_STANDALONE_ARCHIVE" ]] && PYTHON_STANDALONE_ARCHIVE="$ENV_PYTHON_STANDALONE_ARCHIVE"
  [[ -n "$ENV_YTDLP_PACKAGE_SPEC" ]] && YTDLP_PACKAGE_SPEC="$ENV_YTDLP_PACKAGE_SPEC"
fi

TAG="${MANAGED_SUPPORT_TAG:-managed-support}"
TITLE="${MANAGED_SUPPORT_TITLE:-Managed Support}"
MANAGED_SUPPORT_DIR="$ROOT_DIR/dist/managed-support"
TARGET_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  if [[ -n "$CONFIG_FILE" ]]; then
    "$BUILD_SCRIPT" --config "$CONFIG_FILE"
  else
    "$BUILD_SCRIPT"
  fi
fi

[[ -d "$MANAGED_SUPPORT_DIR" ]] || {
  echo "Error: managed support asset directory not found: $MANAGED_SUPPORT_DIR" >&2
  echo "Run scripts/build_managed_support_assets.sh first or omit --skip-build." >&2
  exit 1
}

UPLOAD_ASSETS=()
while IFS= read -r asset_path; do
  UPLOAD_ASSETS+=("$asset_path")
done < <(find "$MANAGED_SUPPORT_DIR" -maxdepth 1 -type f | sort)

[[ "${#UPLOAD_ASSETS[@]}" -gt 0 ]] || {
  echo "Error: no managed support assets found in $MANAGED_SUPPORT_DIR" >&2
  exit 1
}

if gh release view "$TAG" >/dev/null 2>&1; then
  if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || { echo "Error: notes file not found: $NOTES_FILE" >&2; exit 1; }
    gh release edit "$TAG" --title "$TITLE" --notes-file "$NOTES_FILE"
  else
    gh release edit "$TAG" --title "$TITLE"
  fi
else
  if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || { echo "Error: notes file not found: $NOTES_FILE" >&2; exit 1; }
    gh release create "$TAG" --target "$TARGET_COMMIT" --title "$TITLE" --notes-file "$NOTES_FILE"
  else
    gh release create "$TAG" --target "$TARGET_COMMIT" --title "$TITLE" --notes "Managed support payloads for Back Channel"
  fi
fi

gh release upload "$TAG" "${UPLOAD_ASSETS[@]}" --clobber

PUBLISHED_ASSETS=()
while IFS= read -r published_asset; do
  PUBLISHED_ASSETS+=("$published_asset")
done < <(gh release view "$TAG" --json assets --jq '.assets[].name')

MISSING_ASSETS=()
for asset_path in "${UPLOAD_ASSETS[@]}"; do
  asset_name="$(basename "$asset_path")"
  asset_found=0
  for published_asset in "${PUBLISHED_ASSETS[@]}"; do
    if [[ "$published_asset" == "$asset_name" ]]; then
      asset_found=1
      break
    fi
  done
  if [[ "$asset_found" -eq 0 ]]; then
    MISSING_ASSETS+=("$asset_name")
  fi
done

if [[ "${#MISSING_ASSETS[@]}" -gt 0 ]]; then
  echo "Error: managed support upload verification failed. Missing assets on GitHub release:" >&2
  printf '  %s\n' "${MISSING_ASSETS[@]}" >&2
  exit 1
fi

echo "==> Managed support release updated"
echo "Tag: $TAG"
find "$MANAGED_SUPPORT_DIR" -maxdepth 1 -type f | sort | sed 's#^#  #'
