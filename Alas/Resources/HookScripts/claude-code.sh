#!/usr/bin/env bash
# Alas hook for Claude Code Stop and Notification events.
# Receives event JSON on stdin from Claude's hook system, writes a HookEvent JSON
# into $ALAS_HOOK_DIR for Alas to ingest.
set -eu
if [ -z "${ALAS_HOOK_DIR:-}" ]; then exit 0; fi
if [ -z "${ALAS_SESSION_ID:-}" ]; then exit 0; fi

INPUT=$(cat || true)
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

KIND=$(INPUT="$INPUT" python3 -c '
import json, os
try:
    payload = json.loads(os.environ.get("INPUT", "") or "{}")
except Exception:
    payload = {}
event = payload.get("hook_event_name")
if event == "Notification":
    print("awaiting")
else:
    print("stop")
')

SUMMARY=$(INPUT="$INPUT" python3 -c '
import json, os
try:
    payload = json.loads(os.environ.get("INPUT", "") or "{}")
except Exception:
    payload = {}
message = payload.get("message")
if isinstance(message, str) and message:
    print(message[:500])
else:
    print(os.environ.get("INPUT", "")[:500])
')

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
SUMMARY="$SUMMARY" \
SESSION_ID="$ALAS_SESSION_ID" \
TS="$TS" \
KIND="$KIND" \
python3 -c '
import json, os
print(json.dumps({
    "session_id": os.environ["SESSION_ID"],
    "kind": os.environ["KIND"],
    "timestamp": os.environ["TS"],
    "summary": os.environ["SUMMARY"],
}))
' > "$OUT_FILE"
