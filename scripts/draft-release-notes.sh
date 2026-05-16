#!/usr/bin/env bash
# Draft release notes from Conventional Commits.
#
# Usage:
#   ./scripts/draft-release-notes.sh [--since <ref>] [--target <version>]
#                                    [--write] [--include-internal]
set -euo pipefail

SINCE=""
TARGET=""
WRITE=0
INCLUDE_INTERNAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)             SINCE="$2"; shift 2 ;;
    --target)            TARGET="$2"; shift 2 ;;
    --write)             WRITE=1;     shift ;;
    --include-internal)  INCLUDE_INTERNAL=1; shift ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

find_base_ref() {
  if [[ -n "$SINCE" ]]; then
    echo "$SINCE"
    return
  fi
  local tag
  tag=$(git tag --list 'v*' --sort=-v:refname | head -n1 || true)
  if [[ -n "$tag" ]]; then
    echo "$tag"
    return
  fi
  git rev-list --max-parents=0 HEAD | head -n1
}

BASE=$(find_base_ref)

echo "base=$BASE target=${TARGET:-<unreleased>} write=$WRITE include_internal=$INCLUDE_INTERNAL" >&2
