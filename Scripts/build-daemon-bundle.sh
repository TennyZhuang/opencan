#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_DIR="$ROOT_DIR/opencan-daemon"
CACHE_OUTPUT_PATH="${DAEMON_BUNDLE_CACHE_PATH:-$DAEMON_DIR/bin/opencan-daemon-linux-amd64}"
BUNDLE_RELATIVE_PATH="opencan-daemon-linux-amd64"

if [[ "${SKIP_DAEMON_BUNDLE_BUILD:-0}" == "1" ]]; then
  echo "Skipping daemon bundle build (SKIP_DAEMON_BUNDLE_BUILD=1)."
  exit 0
fi

if ! command -v go >/dev/null 2>&1; then
  if [[ -f "$CACHE_OUTPUT_PATH" ]]; then
    echo "warning: 'go' not found; using cached daemon binary: $CACHE_OUTPUT_PATH"
    exit 0
  fi
  echo "error: 'go' not found and cached daemon binary is missing: $CACHE_OUTPUT_PATH" >&2
  exit 1
fi

latest_source_mtime="$(
  find "$DAEMON_DIR" -type f \
    \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' -o -name 'Makefile' \) \
    -print0 | xargs -0 stat -f '%m' | sort -nr | head -1
)"

cache_mtime=0
if [[ -f "$CACHE_OUTPUT_PATH" ]]; then
  cache_mtime="$(stat -f '%m' "$CACHE_OUTPUT_PATH")"
fi

if [[ "$cache_mtime" -lt "$latest_source_mtime" ]]; then
  echo "Building cached daemon binary: $CACHE_OUTPUT_PATH"
  make -C "$DAEMON_DIR" install-ios IOS_BUNDLE_OUTPUT="$CACHE_OUTPUT_PATH"
else
  echo "Cached daemon is up to date: $CACHE_OUTPUT_PATH"
fi

if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  bundle_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
  bundle_output="$bundle_dir/$BUNDLE_RELATIVE_PATH"
  mkdir -p "$bundle_dir"
  install -m 755 "$CACHE_OUTPUT_PATH" "$bundle_output"
  echo "Copied daemon binary into app bundle: $bundle_output"
fi
