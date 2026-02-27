#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_DIR="$ROOT_DIR/opencan-daemon"
BUNDLE_RELATIVE_PATH="opencan-daemon-linux-amd64"

# Xcode build scripts run in a non-login shell, so Homebrew paths are often
# missing from PATH even when Go is installed.
if ! command -v go >/dev/null 2>&1; then
  for bin_dir in /opt/homebrew/bin /usr/local/bin; do
    if [[ -x "$bin_dir/go" ]]; then
      export PATH="$bin_dir:$PATH"
      break
    fi
  done
fi

if [[ "${SKIP_DAEMON_BUNDLE_BUILD:-0}" == "1" ]]; then
  echo "Skipping daemon bundle build (SKIP_DAEMON_BUNDLE_BUILD=1)."
  exit 0
fi

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  echo "error: TARGET_BUILD_DIR and UNLOCALIZED_RESOURCES_FOLDER_PATH are required" >&2
  exit 1
fi

bundle_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
bundle_output="$bundle_dir/$BUNDLE_RELATIVE_PATH"

latest_source_mtime="$(
  find "$DAEMON_DIR" -type f \
    \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' -o -name 'Makefile' \) \
    -print0 | xargs -0 stat -f '%m' | sort -nr | head -1
)"

bundle_mtime=0
if [[ -f "$bundle_output" ]]; then
  bundle_mtime="$(stat -f '%m' "$bundle_output")"
fi

if [[ "$bundle_mtime" -ge "$latest_source_mtime" ]]; then
  echo "Bundled daemon is up to date: $bundle_output"
  exit 0
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: 'go' not found and bundled daemon is stale: $bundle_output" >&2
  exit 1
fi

mkdir -p "$bundle_dir"
echo "Building bundled daemon binary: $bundle_output"
make -C "$DAEMON_DIR" install-ios IOS_BUNDLE_OUTPUT="$bundle_output"
