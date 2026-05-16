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
      sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

preflight_write_unreleased() {
  local file="CHANGELOG.md"
  test -f "$file" || { echo "$file not found" >&2; exit 1; }

  grep -qE '^## \[Unreleased\]$' "$file" || {
    echo "No '## [Unreleased]' heading in $file." >&2
    exit 1
  }
}

preflight_promote_to_target() {
  local target="$1"
  local file="CHANGELOG.md"
  test -f "$file" || { echo "$file not found" >&2; exit 1; }

  grep -qE '^## \[Unreleased\]$' "$file" || {
    echo "No '## [Unreleased]' heading in $file." >&2
    exit 1
  }

  if has_target_section "$target" "$file"; then
    echo "CHANGELOG.md already has a [$target] section." >&2
    exit 1
  fi
}

has_target_section() {
  local target="$1"
  local file="$2"
  local line
  while IFS= read -r line; do
    case "$line" in
      "## [$target]"*) return 0 ;;
    esac
  done < "$file"
  return 1
}

current_unreleased_body() {
  local file="CHANGELOG.md"
  awk '
    /^## \[Unreleased\]$/ { in_unr = 1; next }
    in_unr && /^## \[/ { exit }
    in_unr { print }
  ' "$file" | awk '
    NF { seen = 1 }
    seen { lines = lines $0 ORS }
    END { printf "%s", lines }
  '
}

has_non_whitespace() {
  awk 'NF { found = 1; exit } END { exit found ? 0 : 1 }'
}

if [[ "$WRITE" == 1 && -z "$TARGET" ]]; then
  preflight_write_unreleased
elif [[ "$WRITE" == 1 && -n "$TARGET" ]]; then
  preflight_promote_to_target "$TARGET"
fi

find_base_ref() {
  if [[ -n "$SINCE" ]]; then
    echo "$SINCE"
    return
  fi
  local tag
  tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
  if [[ -n "$tag" ]]; then
    echo "$tag"
    return
  fi
  git rev-list --max-parents=0 HEAD | head -n1
}

if [[ "$WRITE" == 1 && -n "$TARGET" ]]; then
  body=$(current_unreleased_body)
  if ! printf '%s\n' "$body" | has_non_whitespace; then
    echo "No release-note-worthy commits to promote into [$TARGET]; refusing." >&2
    exit 1
  fi

  promote_to_target() {
    local target="$1"
    local release_body="$2"
    local file="CHANGELOG.md"
    local today
    today=$(date +%Y-%m-%d)

    local tmp
    tmp=$(mktemp)
    target="$target" today="$today" release_body="$release_body" awk '
      BEGIN {
        in_unr = 0
        target = ENVIRON["target"]
        today = ENVIRON["today"]
        release_body = ENVIRON["release_body"]
      }
      /^## \[Unreleased\]$/ {
        print "## [Unreleased]"
        print ""
        print "## [" target "] - " today
        print ""
        print release_body
        print ""
        in_unr = 1
        next
      }
      in_unr && /^## \[/ { in_unr = 0 }
      in_unr { next }
      { print }
    ' "$file" > "$tmp"

    awk 'BEGIN{b=0} /^$/{b++; if(b<=1) print; next} {b=0; print}' "$tmp" > "$file"
    rm -f "$tmp"
  }

  promote_to_target "$TARGET" "$body"
  echo "Promoted [Unreleased] to [$TARGET] in CHANGELOG.md." >&2
  exit 0
fi

BASE=$(find_base_ref)

# Conventional Commit type -> group label.
# Types not in this map are dropped.
group_for_type() {
  case "$1" in
    feat)                            echo "✨ Features" ;;
    fix)                             echo "🐛 Fixes" ;;
    refactor|perf|chore)             echo "🏗️ Internal" ;;
    docs)                            echo "📚 Docs" ;;
    ci|test|build|style)
      if [[ "$INCLUDE_INTERNAL" == 1 ]]; then
        echo "🏗️ Internal"
      else
        echo ""
      fi
      ;;
    *) echo "" ;;
  esac
}

# Ordered list so output is deterministic.
GROUP_ORDER=("✨ Features" "🐛 Fixes" "🏗️ Internal" "📚 Docs")

# Per-group bullet accumulators.
FEATURES_BUCKET=""
FIXES_BUCKET=""
INTERNAL_BUCKET=""
DOCS_BUCKET=""

append_to_group() {
  local group="$1"
  local bullet="$2"

  case "$group" in
    "✨ Features") FEATURES_BUCKET+="$bullet"$'\n' ;;
    "🐛 Fixes") FIXES_BUCKET+="$bullet"$'\n' ;;
    "🏗️ Internal") INTERNAL_BUCKET+="$bullet"$'\n' ;;
    "📚 Docs") DOCS_BUCKET+="$bullet"$'\n' ;;
  esac
}

# Subject regex: type(scope)?!?: rest
# Examples matched:
#   feat: x
#   fix(ui): y
#   refactor!: z
#   feat(core)!: w
SUBJECT_RE='^([a-z]+)(\([^)]+\))?!?:[[:space:]]+(.+)$'

subjects=$(git log --pretty=%s --no-merges "$BASE"..HEAD)

while IFS= read -r subject; do
  [[ -z "$subject" ]] && continue
  if [[ "$subject" =~ $SUBJECT_RE ]]; then
    type="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[3]}"
  else
    echo "skip (not conventional): $subject" >&2
    continue
  fi

  group=$(group_for_type "$type")
  if [[ -z "$group" ]]; then
    continue
  fi

  # Trim, append period if missing.
  rest="${rest%"${rest##*[![:space:]]}"}"
  [[ "$rest" != *[.!?] ]] && rest="$rest."

  append_to_group "$group" "- $rest"
done <<< "$subjects"

render_body() {
  local emitted=0
  for group in "${GROUP_ORDER[@]}"; do
    local bullets
    case "$group" in
      "✨ Features") bullets="$FEATURES_BUCKET" ;;
      "🐛 Fixes") bullets="$FIXES_BUCKET" ;;
      "🏗️ Internal") bullets="$INTERNAL_BUCKET" ;;
      "📚 Docs") bullets="$DOCS_BUCKET" ;;
    esac
    if [[ -n "$bullets" ]]; then
      [[ $emitted -gt 0 ]] && echo
      echo "### $group"
      echo
      printf '%s' "$bullets"
      emitted=1
    fi
  done
}

body=$(render_body)

if [[ -z "$body" && ! ( "$WRITE" == 1 && -n "$TARGET" ) ]]; then
  echo "No release-note-worthy commits since $BASE." >&2
  exit 0
fi

write_unreleased() {
  local new_body="$1"
  local file="CHANGELOG.md"
  test -f "$file" || { echo "$file not found" >&2; exit 1; }

  # Verify [Unreleased] heading exists.
  grep -qE '^## \[Unreleased\]$' "$file" || {
    echo "No '## [Unreleased]' heading in $file." >&2
    exit 1
  }

  local tmp
  tmp=$(mktemp)
  new_body="$new_body" awk '
    BEGIN { in_unr = 0; printed_body = 0; new_body = ENVIRON["new_body"] }
    /^## \[Unreleased\]$/ {
      print
      print ""
      if (length(new_body) > 0) {
        print new_body
        print ""
      }
      in_unr = 1
      printed_body = 1
      next
    }
    in_unr && /^## \[/ { in_unr = 0 }
    in_unr { next }   # drop existing Unreleased body
    { print }
  ' "$file" > "$tmp"

  # Collapse any run of >2 blank lines that the splice may have left behind.
  awk 'BEGIN{b=0} /^$/{b++; if(b<=1) print; next} {b=0; print}' "$tmp" > "$file"
  rm -f "$tmp"
}

emit_for_unreleased() {
  # Body without a heading (heading stays in CHANGELOG.md).
  echo "$body"
}

emit_for_target() {
  echo "## [$TARGET] - $(date +%Y-%m-%d)"
  echo
  echo "$body"
}

if [[ -n "$TARGET" ]]; then
  emit_for_target
elif [[ "$WRITE" == 1 ]]; then
  write_unreleased "$body"
  echo "Updated [Unreleased] body in CHANGELOG.md." >&2
else
  echo "## [Unreleased]"
  echo
  echo "$body"
fi
