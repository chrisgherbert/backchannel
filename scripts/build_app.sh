#!/usr/bin/env bash
set -euo pipefail

on_err() {
  local exit_code=$?
  echo "Error: command failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  exit "$exit_code"
}
trap on_err ERR

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="quick"

usage() {
  cat <<USAGE
Usage: scripts/build_app.sh [--mode quick|release]

Builds app bundle to: dist/<APP_NAME>.app
- quick: reuses existing bundled tools/assets when signatures match
- release: always rebuilds full app bundle and rebundles dependencies
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || { echo "Error: --mode requires value" >&2; exit 2; }
      MODE="$2"
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

if [[ "$MODE" != "quick" && "$MODE" != "release" ]]; then
  echo "Error: --mode must be quick or release" >&2
  exit 2
fi

APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Back Channel}"
APP_EXECUTABLE_NAME="${APP_EXECUTABLE_NAME:-Backchannel}"
APP_NAME="${APP_DISPLAY_NAME}.app"
APP_PATH="$ROOT_DIR/dist/$APP_NAME"
MANIFEST_PATH="$APP_PATH/Contents/Resources/.build_app_manifest"
PRODUCT_BIN="$ROOT_DIR/.build/arm64-apple-macosx/release/youtube-live-converter"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package_app.sh"

find_tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  for path in "/opt/homebrew/bin/$name" "/usr/local/bin/$name"; do
    if [[ -x "$path" ]]; then
      echo "$path"
      return 0
    fi
  done
  return 1
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

resolve_tooling() {
  YTDLP_PATH="${YTDLP_BINARY:-}"
  if [[ -z "$YTDLP_PATH" ]]; then
    if [[ -x "$HOME/.local/bin/yt-dlp" ]]; then
      YTDLP_PATH="$HOME/.local/bin/yt-dlp"
    elif command -v yt-dlp >/dev/null 2>&1; then
      YTDLP_PATH="$(command -v yt-dlp)"
    fi
  fi

  FFMPEG_PATH="${FFMPEG_BINARY:-}"
  [[ -n "$FFMPEG_PATH" ]] || FFMPEG_PATH="$(find_tool ffmpeg || true)"

  FFPROBE_PATH="${FFPROBE_BINARY:-}"
  [[ -n "$FFPROBE_PATH" ]] || FFPROBE_PATH="$(find_tool ffprobe || true)"

  DENO_PATH="${DENO_BINARY:-}"
  [[ -n "$DENO_PATH" ]] || DENO_PATH="$(find_tool deno || true)"

  [[ -n "$YTDLP_PATH" && -x "$YTDLP_PATH" ]] || { echo "Error: missing executable yt-dlp (set YTDLP_BINARY)." >&2; exit 1; }
  [[ -n "$FFMPEG_PATH" && -x "$FFMPEG_PATH" ]] || { echo "Error: missing executable ffmpeg (set FFMPEG_BINARY)." >&2; exit 1; }
  [[ -n "$FFPROBE_PATH" && -x "$FFPROBE_PATH" ]] || { echo "Error: missing executable ffprobe (set FFPROBE_BINARY)." >&2; exit 1; }

  if [[ "${DENO_REQUIRED:-0}" == "1" ]]; then
    [[ -n "$DENO_PATH" && -x "$DENO_PATH" ]] || { echo "Error: deno is required for this build (set DENO_BINARY)." >&2; exit 1; }
  fi

  ICON_SOURCE=""
  if [[ -f "$ROOT_DIR/assets/AppIcon.icon" ]]; then
    ICON_SOURCE="$ROOT_DIR/assets/AppIcon.icon"
  elif [[ -f "$ROOT_DIR/assets/AppIcon.png" ]]; then
    ICON_SOURCE="$ROOT_DIR/assets/AppIcon.png"
  fi

  YTDLP_SHA="$(sha256_file "$YTDLP_PATH")"
  FFMPEG_SHA="$(sha256_file "$FFMPEG_PATH")"
  FFPROBE_SHA="$(sha256_file "$FFPROBE_PATH")"
  DENO_SHA=""
  if [[ -n "$DENO_PATH" && -x "$DENO_PATH" ]]; then
    DENO_SHA="$(sha256_file "$DENO_PATH")"
  fi
  ICON_SHA=""
  if [[ -n "$ICON_SOURCE" ]]; then
    ICON_SHA="$(sha256_file "$ICON_SOURCE")"
  fi
}

load_manifest() {
  [[ -f "$MANIFEST_PATH" ]] || return 1
  # shellcheck disable=SC1090
  source "$MANIFEST_PATH"
}

write_manifest() {
  mkdir -p "$(dirname "$MANIFEST_PATH")"
  cat > "$MANIFEST_PATH" <<MANIFEST
YTDLP_PATH='${YTDLP_PATH}'
YTDLP_SHA='${YTDLP_SHA}'
FFMPEG_PATH='${FFMPEG_PATH}'
FFMPEG_SHA='${FFMPEG_SHA}'
FFPROBE_PATH='${FFPROBE_PATH}'
FFPROBE_SHA='${FFPROBE_SHA}'
DENO_PATH='${DENO_PATH}'
DENO_SHA='${DENO_SHA}'
ICON_SHA='${ICON_SHA}'
MANIFEST
}

run_full_package() {
  echo "Running full package build ($MODE mode)..."
  env \
    YTDLP_BINARY="$YTDLP_PATH" \
    FFMPEG_BINARY="$FFMPEG_PATH" \
    FFPROBE_BINARY="$FFPROBE_PATH" \
    DENO_BINARY="$DENO_PATH" \
    DENO_REQUIRED="${DENO_REQUIRED:-0}" \
    APP_DISPLAY_NAME="$APP_DISPLAY_NAME" \
    APP_EXECUTABLE_NAME="$APP_EXECUTABLE_NAME" \
    APP_SHORT_VERSION="${APP_SHORT_VERSION:-}" \
    APP_BUILD_VERSION="${APP_BUILD_VERSION:-}" \
    APP_BUNDLE_ID="${APP_BUNDLE_ID:-}" \
    "$PACKAGE_SCRIPT"
  write_manifest
}

quick_rebundle_needed() {
  [[ -d "$APP_PATH" ]] || return 0
  [[ -x "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME" ]] || return 0
  [[ -d "$APP_PATH/Contents/Resources/bin" ]] || return 0

  local m_ytdlp_path m_ytdlp_sha m_ffmpeg_path m_ffmpeg_sha m_ffprobe_path m_ffprobe_sha m_deno_path m_deno_sha m_icon_sha
  m_ytdlp_path=""; m_ytdlp_sha=""; m_ffmpeg_path=""; m_ffmpeg_sha=""; m_ffprobe_path=""; m_ffprobe_sha=""; m_deno_path=""; m_deno_sha=""; m_icon_sha=""

  if ! load_manifest; then
    return 0
  fi

  m_ytdlp_path="${YTDLP_PATH:-}"
  m_ytdlp_sha="${YTDLP_SHA:-}"
  m_ffmpeg_path="${FFMPEG_PATH:-}"
  m_ffmpeg_sha="${FFMPEG_SHA:-}"
  m_ffprobe_path="${FFPROBE_PATH:-}"
  m_ffprobe_sha="${FFPROBE_SHA:-}"
  m_deno_path="${DENO_PATH:-}"
  m_deno_sha="${DENO_SHA:-}"
  m_icon_sha="${ICON_SHA:-}"

  # restore current-resolved values that were shadowed by sourcing manifest
  resolve_tooling

  [[ "$m_ytdlp_path" == "$YTDLP_PATH" && "$m_ytdlp_sha" == "$YTDLP_SHA" ]] || return 0
  [[ "$m_ffmpeg_path" == "$FFMPEG_PATH" && "$m_ffmpeg_sha" == "$FFMPEG_SHA" ]] || return 0
  [[ "$m_ffprobe_path" == "$FFPROBE_PATH" && "$m_ffprobe_sha" == "$FFPROBE_SHA" ]] || return 0
  [[ "$m_deno_path" == "$DENO_PATH" && "$m_deno_sha" == "$DENO_SHA" ]] || return 0
  [[ "$m_icon_sha" == "$ICON_SHA" ]] || return 0

  return 1
}

quick_copy_binary_only() {
  echo "Quick mode: reusing bundled tools/assets; updating app executable only."
  swift build -c release
  [[ -x "$PRODUCT_BIN" ]] || { echo "Error: built executable missing: $PRODUCT_BIN" >&2; exit 1; }
  cp -f "$PRODUCT_BIN" "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME"
  chmod +x "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME"
  echo "App ready: $APP_PATH"
}

resolve_tooling

if [[ "$MODE" == "release" ]]; then
  run_full_package
  echo "App ready: $APP_PATH"
  exit 0
fi

if quick_rebundle_needed; then
  run_full_package
else
  quick_copy_binary_only
fi

echo "App ready: $APP_PATH"
