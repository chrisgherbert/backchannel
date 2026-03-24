# Back Channel

> Bridge livestreams to RTMP & HLS on macOS.

[Website](https://chrisgherbert.github.io/backchannel/) · [GitHub Releases](https://github.com/chrisgherbert/backchannel/releases) · [Issues](https://github.com/chrisgherbert/backchannel/issues)

Back Channel is a macOS app for turning livestream URLs into RTMP or HLS outputs that fit into production workflows. It is designed for producers, newsroom teams, and technical creators who need a dependable bridge between web livestreams and downstream ingest systems.

## At a Glance

- Converts livestream URLs into RTMP or HLS output
- Supports both GUI and CLI workflows
- Bundles its own core native tooling for end-user installs
- Offers managed support components for broader compatibility and updates
- Built for Apple Silicon Macs running macOS 13 or later

## Website

- GitHub Pages: [chrisgherbert.github.io/backchannel](https://chrisgherbert.github.io/backchannel/)
- Source: [`website/`](/Users/herbert/web/youtube-live-converter/website)
- Workflow: [pages.yml](/Users/herbert/web/youtube-live-converter/.github/workflows/pages.yml)

The marketing/documentation site deploys automatically through GitHub Actions when changes under `website/` are pushed to `main`.

## Release Checklist

1. Ensure standalone `deno` exists for managed support payloads.
2. Optional: set a portable Python runtime URL/archive for the managed `yt-dlp` runtime build, or let the script use its tested default.
3. Create/update private release config:
```bash
cp -n scripts/release.env.example scripts/release.env
```
4. Fill `scripts/release.env` required values (`DEV_ID_APP`, `AC_PROFILE`, `DENO_BINARY`).
5. Run full signed + notarized GitHub release:
```bash
./scripts/github_release.sh --version X.Y.Z --notes-file /absolute/path/to/release-notes.md
```
6. To publish newer managed support payloads without cutting a full app release:
```bash
./scripts/publish_managed_support.sh
```
7. Confirm the GitHub app release includes:
- app zip
- app zip checksum
- `backchannel-managed-support.json`
- managed `yt-dlp` runtime archive + checksum
- managed `deno` archive + checksum
8. Confirm the dedicated `managed-support` release was updated with the same managed assets.
9. Distribute:
```bash
open dist
```

## Prerequisites

- macOS 13+
- portable `ffmpeg` / `ffprobe` binaries available for packaging
- standalone `deno` binary available for managed support packaging
- optional portable Python runtime archive/URL for managed `yt-dlp` packaging

These are release-time/build-time requirements, not end-user runtime requirements. The shipped app bundles or manages its own dependencies.

## Run

```bash
swift run
```

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

This creates `dist/Back Channel.app` and bundles the stable native tools `ffmpeg` and `ffprobe` into:

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
FFMPEG_BINARY=/path/to/ffmpeg FFPROBE_BINARY=/path/to/ffprobe APP_ICON_FILE=/path/to/icon.png ./scripts/package_app.sh
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

`yt-dlp` and `deno` are both managed separately as app support components rather than being sealed inside the `.app` bundle.

### 2. Packaging For Local Testing

Use the packaging script directly:

```bash
./scripts/package_app.sh
```

It will:

1. Build release binary.
2. Create `dist/Back Channel.app`.
3. Bundle required native tools into `Contents/Resources/bin`.
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
- `DENO_BINARY` (standalone Mach-O binary for managed support payloads)

Optional managed-runtime settings:
- `PYTHON_STANDALONE_URL` or `PYTHON_STANDALONE_ARCHIVE`
- `YTDLP_PACKAGE_SPEC`

Create a notarized local release build:

```bash
./scripts/notarize_release.sh
```

Create or update the GitHub release, including managed support assets:

```bash
./scripts/github_release.sh --version X.Y.Z --notes-file /absolute/path/to/release-notes.md
```

The GitHub release script uploads:
- notarized app zip
- app zip checksum
- managed support manifest
- managed yt-dlp archive + checksum
- managed deno archive + checksum

It also republishes those managed support assets to the dedicated `managed-support` release channel so the app can pick up newer `yt-dlp` / `deno` payloads without waiting for a new app build.

If you only want to refresh managed support payloads:

```bash
./scripts/publish_managed_support.sh
```

### 4. Manual Notarization (Reference)

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
   - `Compatible` for stricter ingest-friendly output (`libx264` + `aac`, fixed GOP/CFR)
6. Set `Buffer Delay` in Compatible mode (`No buffer`, `5s`, `15s`, `30s`, `60s`, `120s`; default `30s`) to smooth short source stalls.
   - On start, the app shows an explicit startup buffer countdown in `Status`.
7. Click `Start`.
8. Use `Status` tab for parsed health/progress (including buffer state), and `Advanced` tab for raw console logs.

## Repository Layout

- [`Sources/youtube-live-converter/`](/Users/herbert/web/youtube-live-converter/Sources/youtube-live-converter): Swift app source
- [`scripts/`](/Users/herbert/web/youtube-live-converter/scripts): build, packaging, notarization, and release scripts
- [`website/`](/Users/herbert/web/youtube-live-converter/website): GitHub Pages site
- [`dist/`](/Users/herbert/web/youtube-live-converter/dist): local build outputs

## Notes

- The app captures `yt-dlp` and `ffmpeg` stderr logs in the UI.
- On process failure, it retries with exponential backoff (up to 30 seconds).
- `Stream Copy` may fail if target/container codec compatibility does not match. Use `Compatible` mode in that case.
- Runtime tool resolution prefers:
  - app-managed support components in `~/Library/Application Support/Back Channel/`
  - bundled app resources in `.app/Contents/Resources/bin`
- End users do not need Homebrew, Python, Xcode command line tools, or manually installed runtimes.
