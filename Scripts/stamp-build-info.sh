#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SRCROOT:-}" || -z "${TARGET_BUILD_DIR:-}" || -z "${INFOPLIST_PATH:-}" ]]; then
  echo "error: SRCROOT, TARGET_BUILD_DIR, and INFOPLIST_PATH are required" >&2
  exit 1
fi

plist_path="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
if [[ ! -f "$plist_path" ]]; then
  echo "error: built Info.plist not found at $plist_path" >&2
  exit 1
fi

git_bin="$(xcrun -find git 2>/dev/null || true)"
if [[ -z "$git_bin" ]]; then
  git_bin="$(command -v git || true)"
fi

source_revision="unknown"
source_commit="unknown"
source_repository="https://github.com/TennyZhuang/opencan"
source_commit_url="$source_repository"

normalize_remote_url() {
  local raw="$1"
  raw="${raw%.git}"
  if [[ "$raw" =~ ^git@github\.com:(.+/.+)$ ]]; then
    printf 'https://github.com/%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$raw" =~ ^ssh://git@github\.com/(.+/.+)$ ]]; then
    printf 'https://github.com/%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s\n' "$raw"
}

if [[ -n "$git_bin" ]]; then
  if revision="$("$git_bin" -C "$SRCROOT" rev-parse --short=12 HEAD 2>/dev/null)"; then
    source_revision="$revision"
  fi
  if commit="$("$git_bin" -C "$SRCROOT" rev-parse HEAD 2>/dev/null)"; then
    source_commit="$commit"
  fi
  if remote="$("$git_bin" -C "$SRCROOT" remote get-url origin 2>/dev/null)"; then
    normalized_remote="$(normalize_remote_url "$remote")"
    if [[ -n "$normalized_remote" ]]; then
      source_repository="$normalized_remote"
    fi
  fi
fi

if [[ "$source_commit" != "unknown" && "$source_repository" == https://github.com/* ]]; then
  source_commit_url="$source_repository/tree/$source_commit"
fi

/usr/libexec/PlistBuddy -c "Delete :OpenCANSourceRepository" "$plist_path" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :OpenCANSourceRevision" "$plist_path" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :OpenCANSourceCommit" "$plist_path" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :OpenCANSourceCommitURL" "$plist_path" >/dev/null 2>&1 || true

/usr/libexec/PlistBuddy -c "Add :OpenCANSourceRepository string $source_repository" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :OpenCANSourceRevision string $source_revision" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :OpenCANSourceCommit string $source_commit" "$plist_path"
/usr/libexec/PlistBuddy -c "Add :OpenCANSourceCommitURL string $source_commit_url" "$plist_path"

echo "Stamped build metadata: revision=$source_revision repository=$source_repository"
