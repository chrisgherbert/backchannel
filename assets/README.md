# App Icon

Drop your app icon file here before running:

`./scripts/package_app.sh`

Supported filenames:

- `AppIcon.icon` (Icon Composer package; script extracts primary layer automatically)
- `AppIcon.png` (recommended input; script converts to `.icns`)
- `AppIcon.icns`

Notes:

- Prefer a square PNG with high resolution (1024x1024 works best).
- PNG icons are compiled from PNG source into an Asset Catalog (`Assets.car`) by default.
- PNG icons are normalized before compile only if enabled:
  - transparent-only border trim (`APP_ICON_ALPHA_TRIM_THRESHOLD=0`)
  - non-cropping fit mode (`APP_ICON_FIT_MODE=contain`)
- To disable normalization: `APP_ICON_TRIM_ALPHA=0 ./scripts/package_app.sh`
- To enable normalization: `APP_ICON_TRIM_ALPHA=1 ./scripts/package_app.sh`
- To trim more or less aggressively when normalization is enabled: `APP_ICON_ALPHA_TRIM_THRESHOLD=0 ./scripts/package_app.sh`
- To change scaling behavior:
  - `APP_ICON_FIT_MODE=contain` (default, no crop)
  - `APP_ICON_FIT_MODE=cover` (fills more, may crop edges)
- If `xcrun/actool` is unavailable, the script falls back to `.icns` generation.
- You can also point to another file with:
  - `APP_ICON_FILE=/absolute/path/to/icon.icon ./scripts/package_app.sh`
  - `APP_ICON_FILE=/absolute/path/to/icon.png ./scripts/package_app.sh`
