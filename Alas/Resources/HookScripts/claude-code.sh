#!/usr/bin/env bash
# Alas hook for Claude Code Stop event.
# Receives event JSON on stdin from Claude's hook system, writes a HookEvent JSON
# into $ALAS_HOOK_DIR for Alas to ingest.
set -eu
if [ -z "${ALAS_HOOK_DIR:-}" ]; then exit 0; fi
if [ -z "${ALAS_SESSION_ID:-}" ]; then exit 0; fi

INPUT=$(cat || true)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SUMMARY=$(printf '%s' "$INPUT" | head -c 500 | sed 's/"/\\"/g' | tr -d '\n')

OUT_FILE="$ALAS_HOOK_DIR/$(date -u +%s)-$ALAS_SESSION_ID.json"
mkdir -p "$ALAS_HOOK_DIR"
cat > "$OUT_FILE" <<EOF
{"session_id":"$ALAS_SESSION_ID","kind":"stop","timestamp":"$TS","summary":"$SUMMARY"}
EOF
