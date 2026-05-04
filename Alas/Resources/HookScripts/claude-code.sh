#!/usr/bin/env bash
# Alas hook for Claude Code Stop event.
# Receives event JSON on stdin from Claude's hook system, writes a HookEvent JSON
# into $ALAS_HOOK_DIR for Alas to ingest.
set -eu
if [ -z "${ALAS_HOOK_DIR:-}" ]; then exit 0; fi
if [ -z "${ALAS_SESSION_ID:-}" ]; then exit 0; fi

INPUT=$(cat || true)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Microsecond precision: BSD `date +%s` collides on same-second events,
# which then race in FSEventStream and cause one hook to overwrite another.
TS_US=$(python3 -c 'import time; print(int(time.time()*1_000_000))')
OUT_FILE="$ALAS_HOOK_DIR/$TS_US-$ALAS_SESSION_ID.json"
mkdir -p "$ALAS_HOOK_DIR"

# Serialize via python3's json module so summaries with quotes / backslashes /
# newlines / control chars don't produce invalid JSON. The previous
# `sed 's/"/\\"/g' | tr -d '\n'` left backslashes, tabs, etc. unescaped, which
# made HookEvent.decode silently drop those events. python3 is preinstalled on
# every supported macOS.
SUMMARY="${INPUT:0:500}" \
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
' > "$OUT_FILE"
