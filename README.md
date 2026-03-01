# Backchannel (macOS MVP)

This app runs a persistent pipeline:

`yt-dlp (stdout) -> ffmpeg (stdin) -> RTMP or HLS output`

It is designed to keep `yt-dlp` active for the full stream session, with automatic reconnect attempts.

## Release Checklist

1. Ensure standalone `yt-dlp` exists:
```bash
mkdir -p "$HOME/.local/bin" && curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$HOME/.local/bin/yt-dlp" && chmod +x "$HOME/.local/bin/yt-dlp"
```
2. Create/update private release config:
```bash
cp -n .release.env.example .release.env
```
3. Fill `.release.env` required values (`SIGNING_IDENTITY`, `TEAM_ID`, `NOTARY_KEYCHAIN_PROFILE`, `YTDLP_BINARY`).
4. Run full signed + notarized release:
```bash
./scripts/release_app.sh
```
5. Distribute:
```bash
open dist
```

## Prerequisites

- macOS 13+
- `yt-dlp` installed and available in `PATH`
- `ffmpeg` installed and available in `PATH`

Example installs:

```bash
brew install yt-dlp ffmpeg
```

## Run

```bash
swift run
```

## Website (GitHub Pages)

The marketing site lives in `website/` and deploys automatically via GitHub Actions.

- Workflow: `.github/workflows/pages.yml`
- Hosting: GitHub Pages (default repository Pages URL)
- Auto download target: latest `Back-Channel-<version>.zip` asset from GitHub Releases

How it updates:

1. Edit files under `website/`.
2. Push to `main`.
3. GitHub Actions deploys site automatically.

## Build & Release Workflows

### 1. Local Development Build

Fast local build:

```bash
swift build
```

Run directly from source:

```bash
swift run
```

## Build Self-Contained `.app`

This creates `dist/Back Channel.app` and bundles `yt-dlp` + `ffmpeg` + `ffprobe` (and `deno` when available) into:

`Contents/Resources/bin/`

It also bundles a CLI launcher and installer:

- `Contents/Resources/bin/backchannel`
- `Contents/Resources/bin/install-cli.sh`

```bash
./scripts/package_app.sh
```

App icon (optional):

- Drop `assets/AppIcon.png` (or `assets/AppIcon.icns`) before packaging.
- The script will automatically convert PNG to `.icns`.

You can override tool paths:

```bash
YTDLP_BINARY=/path/to/yt-dlp FFMPEG_BINARY=/path/to/ffmpeg FFPROBE_BINARY=/path/to/ffprobe DENO_BINARY=/path/to/deno APP_ICON_FILE=/path/to/icon.png ./scripts/package_app.sh
```

Install terminal command from the packaged app:

```bash
"/Users/herbert/web/youtube-live-converter/dist/Back Channel.app/Contents/Resources/bin/install-cli.sh"
```

This installs to `~/.local/bin/backchannel` by default (no `sudo`).
For a system-wide install, override target dir:

```bash
CLI_TARGET_DIR=/usr/local/bin "/Users/herbert/web/youtube-live-converter/dist/Back Channel.app/Contents/Resources/bin/install-cli.sh"
```

Then run:

```bash
backchannel --help
```

For distribution to other Macs, use a standalone `yt-dlp` binary. Some Homebrew installs provide a Python wrapper script, which is not portable by itself.
Bundling `deno` is recommended for YouTube extraction reliability.

### 2. Packaging For Local Testing

Use the packaging script directly:

```bash
./scripts/package_app.sh
```

It will:

1. Build release binary.
2. Create `dist/Back Channel.app`.
3. Bundle required tools into `Contents/Resources/bin`.
4. Apply ad-hoc signing (for local execution).

### 3. One-Command Signed + Notarized Release

Use the release script for update distribution:

```bash
./scripts/release_app.sh
```

Before first run:

1. Copy example config:
```bash
cp .release.env.example .release.env
```
2. Fill required values in `.release.env`:
   - `SIGNING_IDENTITY`
   - `TEAM_ID`
   - `NOTARY_KEYCHAIN_PROFILE`
   - `YTDLP_BINARY` (standalone Mach-O binary)

The release script runs:

1. `package_app.sh`
2. Developer ID signing for embedded binaries (`--options runtime --timestamp`)
3. App bundle signing
4. Signature verification
5. Zip creation
6. Notarization submission (`notarytool --wait`)
7. Stapling + validation

Output:

- App: `dist/Back Channel.app`
- Zip: `dist/Back-Channel-<version>.zip` (or `dist/Back-Channel.zip`)

### 4. Standalone `yt-dlp` Binary

Packaging enforces standalone `yt-dlp` (not Python wrapper).

Example install:

```bash
mkdir -p "$HOME/.local/bin" && curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$HOME/.local/bin/yt-dlp" && chmod +x "$HOME/.local/bin/yt-dlp"
```

Set in `.release.env`:

```bash
YTDLP_BINARY="$HOME/.local/bin/yt-dlp"
```

### 5. Manual Notarization (Reference)

If you need to run manually instead of `release_app.sh`:

```bash
codesign --force --options runtime --timestamp --sign "Developer ID Application: <Name> (<TEAMID>)" "dist/Back Channel.app"
ditto -c -k --keepParent "dist/Back Channel.app" "dist/Back-Channel.zip"
xcrun notarytool submit "dist/Back-Channel.zip" --keychain-profile "<profile>" --wait
xcrun stapler staple "dist/Back Channel.app"
xcrun stapler validate "dist/Back Channel.app"
```

## Usage

1. Enter source livestream URL.
2. Click `Load Info` to fetch and preview title/thumbnail/description excerpt.
3. Choose output format:
   - `RTMP` for push targets (`rtmp://server/app/key`)
   - `HLS` for local/served playlist output (`/path/to/out.m3u8`)
4. For RTMP, either:
   - fill `Server URL` + `Stream Key`, or
   - paste a full RTMP URL in `Full RTMP URL (optional override)`
5. Choose mode:
   - `Stream Copy` for lowest CPU (best-effort passthrough)
   - `High Compatibility` for stricter ingest-friendly output (`libx264` + `aac`, fixed GOP/CFR)
6. Set `Buffer Delay` in High Compatibility mode (`No buffer`, `5s`, `15s`, `30s`, `60s`, `120s`; default `30s`) to smooth short source stalls.
   - On start, the app shows an explicit startup buffer countdown in `Status`.
7. Click `Start`.
8. Use `Status` tab for parsed health/progress (including buffer state), and `Advanced` tab for raw console logs.

## Notes

- The app captures `yt-dlp` and `ffmpeg` stderr logs in the UI.
- On process failure, it retries with exponential backoff (up to 30 seconds).
- `Stream Copy` may fail if target/container codec compatibility does not match. Use `High Compatibility` in that case.
- Tool lookup order is:
  - bundled (`.app/Contents/Resources/bin`)
  - `/opt/homebrew/bin`
  - `/usr/local/bin`
