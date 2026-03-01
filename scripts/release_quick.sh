#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${1:-$ROOT_DIR/.release.env}"

NOTARIZE=0 "$ROOT_DIR/scripts/release_app.sh" "$CONFIG_FILE"
