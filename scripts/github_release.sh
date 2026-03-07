#!/usr/bin/env bash
set -euo pipefail

on_err() {
  local exit_code=$?
  echo "Error: command failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  exit "$exit_code"
}
trap on_err ERR

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NOTARIZE_SCRIPT="$ROOT_DIR/scripts/notarize_release.sh"
CONFIG_FILE="$ROOT_DIR/scripts/release.env"

VERSION=""
BUILD_NUMBER=""
SKIP_NOTARIZE=0
NOTES_FILE=""

usage() {
  cat <<USAGE
Usage: scripts/github_release.sh --version X.Y.Z [--build-number N] [--skip-notarize] [--notes-file path]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { echo "Error: --version requires value" >&2; exit 2; }
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      [[ $# -ge 2 ]] || { echo "Error: --build-number requires value" >&2; exit 2; }
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    --notes-file)
      [[ $# -ge 2 ]] || { echo "Error: --notes-file requires value" >&2; exit 2; }
      NOTES_FILE="$2"
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

[[ -n "$VERSION" ]] || { echo "Error: --version is required" >&2; exit 2; }

if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Back Channel}"
SAFE_APP_NAME="${APP_DISPLAY_NAME// /-}"
ZIP_NAME="${ZIP_NAME:-${SAFE_APP_NAME}.zip}"
SOURCE_ZIP="$ROOT_DIR/dist/$ZIP_NAME"

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  "$NOTARIZE_SCRIPT"
fi

[[ -f "$SOURCE_ZIP" ]] || {
  echo "Error: source zip not found: $SOURCE_ZIP" >&2
  echo "Run scripts/notarize_release.sh first or remove --skip-notarize." >&2
  exit 1
}

VERSION_SUFFIX="v${VERSION}"
if [[ -n "$BUILD_NUMBER" ]]; then
  VERSION_SUFFIX+="-build.${BUILD_NUMBER}"
fi

VERSIONED_ZIP="$ROOT_DIR/dist/${SAFE_APP_NAME}-macOS-${VERSION_SUFFIX}.zip"
SHA_FILE="${VERSIONED_ZIP}.sha256"

cp -f "$SOURCE_ZIP" "$VERSIONED_ZIP"
shasum -a 256 "$VERSIONED_ZIP" > "$SHA_FILE"

TAG="v${VERSION}"
TITLE="${APP_DISPLAY_NAME} ${TAG}"
if [[ -n "$BUILD_NUMBER" ]]; then
  TITLE+=" (build ${BUILD_NUMBER})"
fi

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
    gh release create "$TAG" --title "$TITLE" --notes-file "$NOTES_FILE"
  else
    gh release create "$TAG" --title "$TITLE" --notes "Release ${TAG}"
  fi
fi

gh release upload "$TAG" "$VERSIONED_ZIP" "$SHA_FILE" --clobber

echo "==> GitHub release updated"
echo "Tag: $TAG"
echo "Assets:"
echo "  $VERSIONED_ZIP"
echo "  $SHA_FILE"
