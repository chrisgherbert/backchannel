#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DISPLAY_NAME="Backchannel"
APP_NAME="${APP_DISPLAY_NAME}.app"
APP_DIR="$ROOT_DIR/dist/$APP_NAME"
LEGACY_APP_DIR="$ROOT_DIR/dist/YouTube Live Converter.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
RES_BIN_DIR="$RES_DIR/bin"
APP_ICON_NAME="AppIcon"
APP_ICON_ICNS_NAME="${APP_ICON_NAME}.icns"
APP_ICON_PROJECT_NAME="${APP_ICON_NAME}.icon"
DEFAULT_ICON_ICON="$ROOT_DIR/assets/$APP_ICON_PROJECT_NAME"
DEFAULT_ICON_ICNS="$ROOT_DIR/assets/$APP_ICON_ICNS_NAME"
DEFAULT_ICON_PNG="$ROOT_DIR/assets/AppIcon.png"
PRODUCT_BIN="$ROOT_DIR/.build/arm64-apple-macosx/release/youtube-live-converter"
APP_BIN="$BIN_DIR/$APP_DISPLAY_NAME"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.herbert.backchannel}"
APP_BUILD_VERSION="${APP_BUILD_VERSION:-$(date +%Y%m%d%H%M%S)}"
APP_SHORT_VERSION="${APP_SHORT_VERSION:-1.0}"
ICON_ALPHA_TRIM_THRESHOLD="${APP_ICON_ALPHA_TRIM_THRESHOLD:-0}"
ICON_FIT_MODE="${APP_ICON_FIT_MODE:-contain}"
ICON_NORMALIZE_ENABLED="${APP_ICON_TRIM_ALPHA:-0}"

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

is_python_wrapper() {
  local file="$1"
  local first_line
  first_line="$(head -n 1 "$file" || true)"
  [[ "$first_line" == "#!"*python* ]]
}

create_icns_from_png() {
  local png_source="$1"
  local icns_target="$2"
  local tmp_dir iconset_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/backchannel-iconset.XXXXXX")"
  iconset_dir="$tmp_dir/AppIcon.iconset"
  mkdir -p "$iconset_dir"

  # Strip color-management metadata while resizing to avoid visible color/gamma shifts.
  sips --deleteColorManagementProperties -z 16 16 "$png_source" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips --deleteColorManagementProperties -z 32 32 "$png_source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips --deleteColorManagementProperties -z 32 32 "$png_source" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips --deleteColorManagementProperties -z 64 64 "$png_source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips --deleteColorManagementProperties -z 128 128 "$png_source" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips --deleteColorManagementProperties -z 256 256 "$png_source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips --deleteColorManagementProperties -z 256 256 "$png_source" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips --deleteColorManagementProperties -z 512 512 "$png_source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips --deleteColorManagementProperties -z 512 512 "$png_source" --out "$iconset_dir/icon_512x512.png" >/dev/null
  sips --deleteColorManagementProperties -z 1024 1024 "$png_source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$iconset_dir" -o "$icns_target"
  rm -rf "$tmp_dir"
}

compile_asset_catalog_from_png() {
  local png_source="$1"
  local compile_target_dir="$2"
  local tmp_dir xcassets_dir appiconset_dir partial_info
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/backchannel-xcassets.XXXXXX")"
  xcassets_dir="$tmp_dir/Assets.xcassets"
  appiconset_dir="$xcassets_dir/${APP_ICON_NAME}.appiconset"
  partial_info="$tmp_dir/asset-partial-info.plist"
  mkdir -p "$appiconset_dir"

  cat > "$xcassets_dir/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

  cat > "$appiconset_dir/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

  sips --deleteColorManagementProperties -z 16 16 "$png_source" --out "$appiconset_dir/icon_16x16.png" >/dev/null
  sips --deleteColorManagementProperties -z 32 32 "$png_source" --out "$appiconset_dir/icon_16x16@2x.png" >/dev/null
  sips --deleteColorManagementProperties -z 32 32 "$png_source" --out "$appiconset_dir/icon_32x32.png" >/dev/null
  sips --deleteColorManagementProperties -z 64 64 "$png_source" --out "$appiconset_dir/icon_32x32@2x.png" >/dev/null
  sips --deleteColorManagementProperties -z 128 128 "$png_source" --out "$appiconset_dir/icon_128x128.png" >/dev/null
  sips --deleteColorManagementProperties -z 256 256 "$png_source" --out "$appiconset_dir/icon_128x128@2x.png" >/dev/null
  sips --deleteColorManagementProperties -z 256 256 "$png_source" --out "$appiconset_dir/icon_256x256.png" >/dev/null
  sips --deleteColorManagementProperties -z 512 512 "$png_source" --out "$appiconset_dir/icon_256x256@2x.png" >/dev/null
  sips --deleteColorManagementProperties -z 512 512 "$png_source" --out "$appiconset_dir/icon_512x512.png" >/dev/null
  sips --deleteColorManagementProperties -z 1024 1024 "$png_source" --out "$appiconset_dir/icon_512x512@2x.png" >/dev/null

  xcrun actool "$xcassets_dir" \
    --compile "$compile_target_dir" \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 13.0 \
    --app-icon "$APP_ICON_NAME" \
    --output-partial-info-plist "$partial_info" >/dev/null

  rm -rf "$tmp_dir"
}

extract_png_from_icon_project() {
  local icon_project_dir="$1"
  local png_target="$2"

  swift - "$icon_project_dir" "$png_target" <<'SWIFT'
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { exit(2) }

let iconDir = URL(fileURLWithPath: args[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: args[2])
let iconJSONURL = iconDir.appendingPathComponent("icon.json")
let assetsDirURL = iconDir.appendingPathComponent("Assets", isDirectory: true)

guard
  let jsonData = try? Data(contentsOf: iconJSONURL),
  let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
else {
  exit(3)
}

var selectedImageName: String?
if let groups = root["groups"] as? [[String: Any]] {
  outer: for group in groups {
    guard let layers = group["layers"] as? [[String: Any]] else { continue }
    for layer in layers {
      if (layer["hidden"] as? Bool) == true { continue }
      if let imageName = layer["image-name"] as? String, !imageName.isEmpty {
        selectedImageName = imageName
        break outer
      }
    }
  }
}

if selectedImageName == nil {
  let files = (try? FileManager.default.contentsOfDirectory(
    at: assetsDirURL,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
  )) ?? []
  selectedImageName = files
    .filter { $0.pathExtension.lowercased() == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .first?
    .lastPathComponent
}

guard let imageName = selectedImageName else {
  exit(4)
}

let sourcePNG = assetsDirURL.appendingPathComponent(imageName)
guard FileManager.default.fileExists(atPath: sourcePNG.path) else {
  exit(5)
}

do {
  if FileManager.default.fileExists(atPath: outputURL.path) {
    try FileManager.default.removeItem(at: outputURL)
  }
  try FileManager.default.copyItem(at: sourcePNG, to: outputURL)
} catch {
  exit(6)
}
SWIFT
}

normalize_icon_png() {
  local png_source="$1"
  local png_target="$2"
  local alpha_threshold="$3"
  local fit_mode="$4"

  swift - "$png_source" "$png_target" "$alpha_threshold" "$fit_mode" <<'SWIFT'
import Foundation
import AppKit

let args = CommandLine.arguments
guard args.count == 5 else { exit(2) }

let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let alphaThreshold = UInt8(max(0, min(255, Int(args[3]) ?? 16)))
let fitMode = args[4].lowercased()

guard
  let inputData = try? Data(contentsOf: inputURL),
  let inputRep = NSBitmapImageRep(data: inputData),
  let inputCG = inputRep.cgImage
else {
  exit(3)
}

let width = inputCG.width
let height = inputCG.height
guard width > 0, height > 0 else { exit(4) }

guard let scanContext = CGContext(
  data: nil,
  width: width,
  height: height,
  bitsPerComponent: 8,
  bytesPerRow: width * 4,
  space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  exit(5)
}

scanContext.draw(inputCG, in: CGRect(x: 0, y: 0, width: width, height: height))

guard let scanData = scanContext.data else { exit(6) }
let pixels = scanData.bindMemory(to: UInt8.self, capacity: width * height * 4)

var minX = width
var minY = height
var maxX = -1
var maxY = -1

for y in 0..<height {
  for x in 0..<width {
    let alpha = pixels[(y * width + x) * 4 + 3]
    if alpha > alphaThreshold {
      if x < minX { minX = x }
      if y < minY { minY = y }
      if x > maxX { maxX = x }
      if y > maxY { maxY = y }
    }
  }
}

let cropRect: CGRect
if maxX >= minX && maxY >= minY {
  cropRect = CGRect(
    x: minX,
    y: minY,
    width: maxX - minX + 1,
    height: maxY - minY + 1
  )
} else {
  cropRect = CGRect(x: 0, y: 0, width: width, height: height)
}

guard let cropped = inputCG.cropping(to: cropRect) else { exit(7) }

let outputSize = CGSize(width: 1024, height: 1024)
guard let outContext = CGContext(
  data: nil,
  width: Int(outputSize.width),
  height: Int(outputSize.height),
  bitsPerComponent: 8,
  bytesPerRow: Int(outputSize.width) * 4,
  space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  exit(8)
}

outContext.setFillColor(NSColor.clear.cgColor)
outContext.fill(CGRect(origin: .zero, size: outputSize))

let widthScale = outputSize.width / cropRect.width
let heightScale = outputSize.height / cropRect.height
let scale: CGFloat
if fitMode == "cover" {
  scale = max(widthScale, heightScale)
} else {
  scale = min(widthScale, heightScale)
}
let drawWidth = cropRect.width * scale
let drawHeight = cropRect.height * scale
let drawRect = CGRect(
  x: (outputSize.width - drawWidth) / 2,
  y: (outputSize.height - drawHeight) / 2,
  width: drawWidth,
  height: drawHeight
)

outContext.draw(cropped, in: drawRect)

guard
  let outputCG = outContext.makeImage(),
  let outputRep = NSBitmapImageRep(cgImage: outputCG).representation(using: .png, properties: [:])
else {
  exit(9)
}

do {
  try outputRep.write(to: outputURL)
} catch {
  exit(10)
}
SWIFT
}

echo "Building release binary..."
cd "$ROOT_DIR"
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_DIR"
if [[ -d "$LEGACY_APP_DIR" ]] && [[ "$LEGACY_APP_DIR" != "$APP_DIR" ]]; then
  rm -rf "$LEGACY_APP_DIR"
fi
mkdir -p "$BIN_DIR" "$RES_DIR" "$RES_BIN_DIR"
cp "$PRODUCT_BIN" "$APP_BIN"
chmod +x "$APP_BIN"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$APP_BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_SHORT_VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconName</key>
    <string>$APP_ICON_NAME</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

ICON_SOURCE="${APP_ICON_FILE:-}"
if [[ -z "$ICON_SOURCE" ]]; then
  if [[ -d "$DEFAULT_ICON_ICON" ]]; then
    ICON_SOURCE="$DEFAULT_ICON_ICON"
  elif [[ -f "$DEFAULT_ICON_ICNS" ]]; then
    ICON_SOURCE="$DEFAULT_ICON_ICNS"
  elif [[ -f "$DEFAULT_ICON_PNG" ]]; then
    ICON_SOURCE="$DEFAULT_ICON_PNG"
  fi
fi

if [[ -n "$ICON_SOURCE" ]] && [[ -e "$ICON_SOURCE" ]]; then
  rm -f "$RES_DIR/$APP_ICON_ICNS_NAME" "$RES_DIR/Assets.car"
  icon_extension="${ICON_SOURCE##*.}"
  icon_extension="$(printf '%s' "$icon_extension" | tr '[:upper:]' '[:lower:]')"
  case "$icon_extension" in
    icns)
      cp "$ICON_SOURCE" "$RES_DIR/$APP_ICON_ICNS_NAME"
      /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
      /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $APP_ICON_NAME" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || \
      /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $APP_ICON_NAME" "$APP_DIR/Contents/Info.plist"
      echo "Using app icon (.icns): $ICON_SOURCE"
      ;;
    png|icon)
      if ! command -v sips >/dev/null 2>&1; then
        echo "Error: sips is required to convert PNG app icons." >&2
        exit 1
      fi
      if ! command -v xcrun >/dev/null 2>&1; then
        echo "Warning: xcrun not found, falling back to .icns generation." >&2
      fi
      icon_temp_png=""
      source_png="$ICON_SOURCE"
      if [[ "$icon_extension" == "icon" ]]; then
        if [[ ! -d "$ICON_SOURCE" ]]; then
          echo "Error: .icon source must be a directory package: $ICON_SOURCE" >&2
          exit 1
        fi
        icon_temp_png="$(mktemp "${TMPDIR:-/tmp}/backchannel-iconcomposer.XXXXXX.png")"
        if extract_png_from_icon_project "$ICON_SOURCE" "$icon_temp_png"; then
          source_png="$icon_temp_png"
          echo "Extracted Icon Composer source image from: $ICON_SOURCE"
        else
          echo "Error: failed to read Icon Composer package: $ICON_SOURCE" >&2
          rm -f "$icon_temp_png"
          exit 1
        fi
      fi

      normalized_png="$source_png"
      normalized_png_tmp=""
      if [[ "$ICON_NORMALIZE_ENABLED" != "0" ]]; then
        normalized_png_tmp="$(mktemp "${TMPDIR:-/tmp}/backchannel-icon-normalized.XXXXXX.png")"
        if normalize_icon_png "$source_png" "$normalized_png_tmp" "$ICON_ALPHA_TRIM_THRESHOLD" "$ICON_FIT_MODE"; then
          normalized_png="$normalized_png_tmp"
          echo "Normalized icon (trim alpha threshold: $ICON_ALPHA_TRIM_THRESHOLD, fit mode: $ICON_FIT_MODE)."
        else
          echo "Warning: failed to normalize PNG icon. Using original PNG." >&2
          rm -f "$normalized_png_tmp"
          normalized_png_tmp=""
        fi
      else
        echo "Using source PNG as-is (no normalization)."
      fi

      if command -v xcrun >/dev/null 2>&1; then
        if compile_asset_catalog_from_png "$normalized_png" "$RES_DIR"; then
          /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
          /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $APP_ICON_NAME" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || \
          /usr/libexec/PlistBuddy -c "Set :CFBundleIconName $APP_ICON_NAME" "$APP_DIR/Contents/Info.plist"
          echo "Using app icon (PNG source compiled into Assets.car): $ICON_SOURCE"
        else
          echo "Warning: asset catalog compile failed, falling back to .icns generation." >&2
          create_icns_from_png "$normalized_png" "$RES_DIR/$APP_ICON_ICNS_NAME"
          /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
          /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $APP_ICON_NAME" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || \
          /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $APP_ICON_NAME" "$APP_DIR/Contents/Info.plist"
          echo "Using app icon (.png converted to .icns fallback): $ICON_SOURCE"
        fi
      else
        create_icns_from_png "$normalized_png" "$RES_DIR/$APP_ICON_ICNS_NAME"
        /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $APP_ICON_NAME" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $APP_ICON_NAME" "$APP_DIR/Contents/Info.plist"
        echo "Using app icon (.png converted to .icns fallback): $ICON_SOURCE"
      fi
      if [[ -n "$normalized_png_tmp" ]]; then
        rm -f "$normalized_png_tmp"
      fi
      if [[ -n "$icon_temp_png" ]]; then
        rm -f "$icon_temp_png"
      fi
      ;;
    *)
      echo "Error: unsupported icon format: $ICON_SOURCE" >&2
      echo "Use a .icon package, .png, or .icns file for APP_ICON_FILE." >&2
      exit 1
      ;;
  esac
else
  echo "No app icon found (optional)."
  echo "Drop one of these files and re-run packaging:"
  echo "  $DEFAULT_ICON_ICON"
  echo "  $DEFAULT_ICON_PNG"
  echo "  $DEFAULT_ICON_ICNS"
  echo "Or set APP_ICON_FILE=/absolute/path/icon.icon (or .png/.icns)."
fi

echo "Bundling yt-dlp, ffmpeg, ffprobe, and deno (if available)..."
YTDLP_PATH="${YTDLP_BINARY:-}"
if [[ -z "$YTDLP_PATH" ]]; then
  YTDLP_PATH="$(find_tool yt-dlp)" || {
    echo "Error: yt-dlp not found. Install it first (brew install yt-dlp)." >&2
    exit 1
  }
fi

FFMPEG_PATH="${FFMPEG_BINARY:-}"
if [[ -z "$FFMPEG_PATH" ]]; then
  FFMPEG_PATH="$(find_tool ffmpeg)" || {
    echo "Error: ffmpeg not found. Install it first (brew install ffmpeg)." >&2
    exit 1
  }
fi

FFPROBE_PATH="${FFPROBE_BINARY:-}"
if [[ -z "$FFPROBE_PATH" ]]; then
  FFPROBE_PATH="$(find_tool ffprobe)" || {
    probe_next_to_ffmpeg="$(dirname "$FFMPEG_PATH")/ffprobe"
    if [[ -x "$probe_next_to_ffmpeg" ]]; then
      FFPROBE_PATH="$probe_next_to_ffmpeg"
    else
      echo "Error: ffprobe not found. Install ffmpeg package with ffprobe included." >&2
      exit 1
    fi
  }
fi

DENO_PATH="${DENO_BINARY:-}"
if [[ -z "$DENO_PATH" ]]; then
  DENO_PATH="$(find_tool deno || true)"
fi

if [[ ! -x "$YTDLP_PATH" ]]; then
  echo "Error: YTDLP_BINARY is not executable: $YTDLP_PATH" >&2
  exit 1
fi
if [[ ! -x "$FFMPEG_PATH" ]]; then
  echo "Error: FFMPEG_BINARY is not executable: $FFMPEG_PATH" >&2
  exit 1
fi
if [[ ! -x "$FFPROBE_PATH" ]]; then
  echo "Error: FFPROBE_BINARY is not executable: $FFPROBE_PATH" >&2
  exit 1
fi
if [[ -n "$DENO_PATH" ]] && [[ ! -x "$DENO_PATH" ]]; then
  echo "Error: DENO_BINARY is not executable: $DENO_PATH" >&2
  exit 1
fi

if is_python_wrapper "$YTDLP_PATH"; then
  echo "Warning: yt-dlp appears to be a Python wrapper script."
  echo "Warning: for portable distribution, set YTDLP_BINARY to a standalone yt-dlp binary."
fi

rm -f "$RES_BIN_DIR/yt-dlp" "$RES_BIN_DIR/ffmpeg" "$RES_BIN_DIR/ffprobe" "$RES_BIN_DIR/deno"
cp "$YTDLP_PATH" "$RES_BIN_DIR/yt-dlp"
cp "$FFMPEG_PATH" "$RES_BIN_DIR/ffmpeg"
cp "$FFPROBE_PATH" "$RES_BIN_DIR/ffprobe"
if [[ -n "$DENO_PATH" ]]; then
  cp "$DENO_PATH" "$RES_BIN_DIR/deno"
  chmod +x "$RES_BIN_DIR/deno"
fi
chmod +x "$RES_BIN_DIR/yt-dlp" "$RES_BIN_DIR/ffmpeg" "$RES_BIN_DIR/ffprobe"

echo "Bundled:"
echo "  yt-dlp: $YTDLP_PATH"
echo "  ffmpeg: $FFMPEG_PATH"
echo "  ffprobe: $FFPROBE_PATH"
if [[ -n "$DENO_PATH" ]]; then
  echo "  deno: $DENO_PATH"
else
  echo "  deno: not bundled (optional)"
fi

echo "Signing app bundle..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "App bundle ready:"
echo "  $APP_DIR"
