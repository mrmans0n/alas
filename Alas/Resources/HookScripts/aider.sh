#!/usr/bin/env bash
# Alas hook for Aider completion. Hardcoded summary today; switch to python3
# JSON serialization for consistency with the other hooks (and to ensure any
# future caller-provided summary is escaped correctly).
set -eu
if [ -z "${ALAS_HOOK_DIR:-}" ] || [ -z "${ALAS_SESSION_ID:-}" ]; then exit 0; fi
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$ALAS_HOOK_DIR"
# Microsecond precision: BSD `date +%s` collides on same-second events.
TS_US=$(python3 -c 'import time; print(int(time.time()*1_000_000))')
OUT="$ALAS_HOOK_DIR/$TS_US-$ALAS_SESSION_ID.json"
SUMMARY="Aider finished" \
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
