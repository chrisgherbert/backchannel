# Backchannel (macOS MVP)

This app runs a persistent pipeline:

`yt-dlp (stdout) -> ffmpeg (stdin) -> RTMP or HLS output`

It is designed to keep `yt-dlp` active for the full stream session, with automatic reconnect attempts.

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

## Build Self-Contained `.app`

This creates `dist/Backchannel.app` and bundles `yt-dlp` + `ffmpeg` + `ffprobe` (and `deno` when available) into:

`Contents/Resources/bin/`

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

For distribution to other Macs, use a standalone `yt-dlp` binary. Some Homebrew installs provide a Python wrapper script, which is not portable by itself.
Bundling `deno` is recommended for YouTube extraction reliability.

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
