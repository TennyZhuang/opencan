#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_DIR="$ROOT_DIR/opencan-daemon"
BUNDLE_RELATIVE_PATH="opencan-daemon-linux-amd64"

if [[ "${SKIP_DAEMON_BUNDLE_BUILD:-0}" == "1" ]]; then
  echo "Skipping daemon bundle build (SKIP_DAEMON_BUNDLE_BUILD=1)."
  exit 0
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: 'go' not found; daemon bundle must be rebuilt for each app build" >&2
  exit 1
fi

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  echo "error: TARGET_BUILD_DIR and UNLOCALIZED_RESOURCES_FOLDER_PATH are required" >&2
  exit 1
fi

bundle_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
bundle_output="$bundle_dir/$BUNDLE_RELATIVE_PATH"
mkdir -p "$bundle_dir"
echo "Building bundled daemon binary: $bundle_output"
make -C "$DAEMON_DIR" install-ios IOS_BUNDLE_OUTPUT="$bundle_output"
