#!/usr/bin/env bash
set -uo pipefail

# Runs a command and fails it once its output has been silent for <seconds>,
# printing every descendant's stacks first (`sample` on macOS, `gdb` where
# installed elsewhere), so a hung test run ends with evidence instead of at
# the job's timeout.
#
# Usage: scripts/run-with-stall-watchdog.sh <seconds> <command> [args...]
# Exits with the command's status, or 124 after a stall.

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <seconds> <command> [args...]" >&2
  exit 2
fi
limit="$1"
shift

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
"$@" > >(tee "$log") 2>&1 &
pid=$!

descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    echo "$child"
    descendants "$child"
  done
}

last_size=-1
silent=0
while kill -0 "$pid" 2>/dev/null; do
  sleep 10
  size="$(wc -c < "$log")"
  if [ "$size" = "$last_size" ]; then
    silent=$((silent + 10))
  else
    silent=0
    last_size="$size"
  fi
  [ "$silent" -ge "$limit" ] || continue

  echo "::error::No output for ${limit}s; sampling and stopping: $*"
  for process in $(descendants "$pid"); do
    echo "===== $(ps -o pid=,command= -p "$process" | cut -c1-200)"
    if command -v sample >/dev/null; then
      sample "$process" 3 2>&1
    elif command -v gdb >/dev/null; then
      gdb -p "$process" -batch -ex 'thread apply all bt' 2>&1
    fi
  done
  descendants "$pid" | xargs kill -9 2>/dev/null
  kill -9 "$pid" 2>/dev/null
  exit 124
done
wait "$pid"
