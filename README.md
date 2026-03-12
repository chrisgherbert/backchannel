# Backchannel (macOS MVP)

This app runs a persistent pipeline:

`yt-dlp (stdout) -> ffmpeg (stdin) -> RTMP or HLS output`

It is designed to keep `yt-dlp` active for the full stream session, with automatic reconnect attempts.

## Release Checklist

1. Ensure standalone `yt-dlp` exists:
```bash
mkdir -p "$HOME/.local/bin" && curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$HOME/.local/bin/yt-dlp" && chmod +x "$HOME/.local/bin/yt-dlp"
```
2. Ensure standalone `deno` exists for managed support payloads.
3. Create/update private release config:
```bash
cp -n scripts/release.env.example scripts/release.env
```
4. Fill `scripts/release.env` required values (`DEV_ID_APP`, `AC_PROFILE`, `YTDLP_BINARY`, `DENO_BINARY`).
5. Run full signed + notarized GitHub release:
```bash
./scripts/github_release.sh --version 1.1.1 --notes-file /absolute/path/to/release-notes.md
```
6. Confirm the GitHub release includes:
- app zip
- app zip checksum
- `backchannel-managed-support.json`
- managed `yt-dlp` archive + checksum
- managed `deno` archive + checksum
7. Distribute:
```bash
open dist
```

## Prerequisites

- macOS 13+
- standalone `yt-dlp` binary available for packaging
- portable `ffmpeg` / `ffprobe` binaries available for packaging
- standalone `deno` binary available for managed support packaging

These are release-time/build-time requirements, not end-user runtime requirements. The shipped app bundles or manages its own dependencies.

Example `yt-dlp` install:

```bash
mkdir -p "$HOME/.local/bin" && curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$HOME/.local/bin/yt-dlp" && chmod +x "$HOME/.local/bin/yt-dlp"
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

### 3. Signed + Notarized Release

Use the current release pipeline scripts:

First-time setup:

```bash
cp scripts/release.env.example scripts/release.env
```

Fill required values in `scripts/release.env`:
- `DEV_ID_APP`
- `AC_PROFILE`
- `YTDLP_BINARY` (standalone Mach-O binary)
- `DENO_BINARY` (standalone Mach-O binary for managed support payloads)

Create a notarized local release build:

```bash
./scripts/notarize_release.sh
```

Create or update the GitHub release, including managed support assets:

```bash
./scripts/github_release.sh --version 1.1.1 --notes-file /absolute/path/to/release-notes.md
```

The GitHub release script uploads:
- notarized app zip
- app zip checksum
- managed support manifest
- managed yt-dlp archive + checksum
- managed deno archive + checksum

It also verifies that those assets actually exist on the GitHub release after upload. If any are missing, the script fails.

### 4. Standalone `yt-dlp` Binary

Packaging enforces standalone `yt-dlp` (not Python wrapper).

Example install:

```bash
mkdir -p "$HOME/.local/bin" && curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$HOME/.local/bin/yt-dlp" && chmod +x "$HOME/.local/bin/yt-dlp"
```

Set in `scripts/release.env`:

```bash
YTDLP_BINARY="$HOME/.local/bin/yt-dlp"
```

### 5. Manual Notarization (Reference)

If you need to run manual notarization steps instead of `scripts/notarize_release.sh`:

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
