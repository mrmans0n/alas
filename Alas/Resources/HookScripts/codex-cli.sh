#!/usr/bin/env bash
# Alas hook for Codex CLI completion. Caller invokes this with a summary as $1.
set -eu
if [ -z "${ALAS_HOOK_DIR:-}" ] || [ -z "${ALAS_SESSION_ID:-}" ]; then exit 0; fi
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$ALAS_HOOK_DIR"
OUT="$ALAS_HOOK_DIR/$(date -u +%s)-$ALAS_SESSION_ID.json"
# Serialize via python3 so summaries with embedded quotes / backslashes /
# newlines produce valid JSON instead of silently invalid output that
# HookEvent.decode would drop.
SUMMARY="${1:-Codex finished}" \
SESSION_ID="$ALAS_SESSION_ID" \
TS="$TS" \
python3 -c '
import json, os
print(json.dumps({
    "session_id": os.environ["SESSION_ID"],
    "kind": "stop",
    "timestamp": os.environ["TS"],
    "summary": os.environ["SUMMARY"],
}))
' > "$OUT"
