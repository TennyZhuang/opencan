#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_DIR="$ROOT_DIR/opencan-daemon"
DEFAULT_DAEMON_TARGETS="linux-amd64"

raw_targets="${OPENCAN_DAEMON_BUNDLE_TARGETS:-$DEFAULT_DAEMON_TARGETS}"
raw_targets="${raw_targets//;/,}"
raw_targets="${raw_targets// /,}"

declare -a daemon_targets=()
seen_targets=","
IFS=',' read -r -a parsed_targets <<< "$raw_targets"
for target in "${parsed_targets[@]}"; do
  target="${target//[[:space:]]/}"
  if [[ -z "$target" || "$seen_targets" == *",$target,"* ]]; then
    continue
  fi
  seen_targets+="$target,"
  daemon_targets+=("$target")
done

if [[ "${#daemon_targets[@]}" -eq 0 ]]; then
  daemon_targets=("$DEFAULT_DAEMON_TARGETS")
fi

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

daemon_version="$(
  awk -F':=' '/^VERSION[[:space:]]*:=[[:space:]]*/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' \
    "$DAEMON_DIR/Makefile"
)"
if [[ -z "$daemon_version" ]]; then
  daemon_version="0.1.0"
fi

latest_source_mtime="$(
  find "$DAEMON_DIR" -type f \
    \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' -o -name 'Makefile' \) \
    -print0 | xargs -0 stat -f '%m' | sort -nr | head -1
)"

if ! command -v go >/dev/null 2>&1; then
  echo "error: 'go' not found and bundled daemon is stale" >&2
  exit 1
fi

mkdir -p "$bundle_dir"
for target in "${daemon_targets[@]}"; do
  os="${target%-*}"
  arch="${target#*-}"
  if [[ -z "$os" || -z "$arch" || "$os" == "$arch" ]]; then
    echo "error: invalid OPENCAN_DAEMON_BUNDLE_TARGETS entry '$target' (expected os-arch)" >&2
    exit 1
  fi

  bundle_output="$bundle_dir/opencan-daemon-$target"
  bundle_mtime=0
  if [[ -f "$bundle_output" ]]; then
    bundle_mtime="$(stat -f '%m' "$bundle_output")"
  fi

  if [[ "$bundle_mtime" -ge "$latest_source_mtime" ]]; then
    echo "Bundled daemon is up to date: $bundle_output"
    continue
  fi

  echo "Building bundled daemon binary: $bundle_output"
  (
    cd "$DAEMON_DIR"
    GOOS="$os" GOARCH="$arch" go build \
      -ldflags="-s -w -X main.version=$daemon_version" \
      -o "$bundle_output" \
      ./cmd/opencan-daemon
  )
done
