#!/usr/bin/env bash
# Alas hook for Aider completion/awaiting events. By default this emits
# completion; callers that have a reliable waiting signal can pass `--kind awaiting`.
set -eu
if [ -z "${ALAS_HOOK_DIR:-}" ] || [ -z "${ALAS_SESSION_ID:-}" ]; then exit 0; fi
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$ALAS_HOOK_DIR"
# Microsecond precision: BSD `date +%s` collides on same-second events.
TS_US=$(python3 -c 'import time; print(int(time.time()*1_000_000))')
OUT="$ALAS_HOOK_DIR/$TS_US-$ALAS_SESSION_ID.json"
KIND="${ALAS_HOOK_KIND:-stop}"
if [ "${1:-}" = "--kind" ]; then
    KIND="${2:-stop}"
    shift 2
elif [ "${1:-}" = "awaiting" ] || [ "${1:-}" = "stop" ]; then
    KIND="$1"
    shift
fi
if [ "$KIND" = "awaiting" ]; then
    DEFAULT_SUMMARY="Aider is waiting for input"
else
    DEFAULT_SUMMARY="Aider finished"
fi
SUMMARY="${1:-$DEFAULT_SUMMARY}" \
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
' > "$OUT"
