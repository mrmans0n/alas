#!/usr/bin/env bash
set -eu
if [ -z "${ALAS_HOOK_DIR:-}" ] || [ -z "${ALAS_SESSION_ID:-}" ]; then exit 0; fi
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SUMMARY="${1:-Codex finished}"
mkdir -p "$ALAS_HOOK_DIR"
OUT="$ALAS_HOOK_DIR/$(date -u +%s)-$ALAS_SESSION_ID.json"
printf '{"session_id":"%s","kind":"stop","timestamp":"%s","summary":"%s"}\n' \
    "$ALAS_SESSION_ID" "$TS" "$SUMMARY" > "$OUT"
