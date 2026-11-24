#!/usr/bin/env bash
set -uo pipefail

# Runs a command and fails it once its output has been silent for <seconds>,
# printing every descendant's stacks first (`sample` on macOS, `gdb` where
# installed elsewhere), so a hung test run ends with evidence instead of at
# the job's timeout.
#
# Usage: scripts/run-with-stall-watchdog.sh <seconds> [--buffer-output]
#        [--log-file <path>] <command> [args...]
# Exits with the command's status, or 124 after a stall.

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <seconds> [--buffer-output] [--log-file <path>] <command> [args...]" >&2
  exit 2
fi
limit="$1"
shift
buffer_output=false
log=""
remove_log=true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --buffer-output)
      buffer_output=true
      shift
      ;;
    --log-file)
      if [ "$#" -lt 2 ]; then
        echo "--log-file requires a path" >&2
        exit 2
      fi
      log="$2"
      remove_log=false
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done
if [ "$#" -lt 1 ]; then
  echo "usage: $0 <seconds> [--buffer-output] [--log-file <path>] <command> [args...]" >&2
  exit 2
fi

if [ -z "$log" ]; then
  log="$(mktemp)"
else
  : > "$log"
fi
trap 'if [ "$remove_log" = true ]; then rm -f "$log"; fi' EXIT
if [ "$buffer_output" = true ]; then
  "$@" >> "$log" 2>&1 &
else
  "$@" > >(tee -a "$log") 2>&1 &
fi
pid=$!

emit_bounded_excerpt() {
  local head_lines="$1"
  local tail_lines="$2"
  local head_bytes="$3"
  local tail_bytes="$4"
  local size lines limit_bytes limit_lines
  size="$(wc -c < "$log")"
  lines="$(wc -l < "$log")"
  limit_bytes=$((head_bytes + tail_bytes))
  limit_lines=$((head_lines + tail_lines))
  if [ "$size" -le "$limit_bytes" ] && [ "$lines" -le "$limit_lines" ]; then
    cat "$log"
    return
  fi
  if [ "$head_lines" -gt 0 ]; then
    head -n "$head_lines" "$log" | dd bs="$head_bytes" count=1 2>/dev/null
  fi
  if [ "$remove_log" = true ]; then
    printf '\n... diagnostic output truncated; the complete temporary log will be removed ...\n'
  else
    printf '\n... diagnostic output truncated; complete log retained at %s ...\n' "$log"
  fi
  tail -n "$tail_lines" "$log" | tail -c "$tail_bytes"
}

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

  echo "::error::No output for ${limit}s; sampling and stopping the buffered command"
  if [ "$buffer_output" = true ]; then
    emit_bounded_excerpt 80 320 65536 131072
  fi
  # Keep complete samples in the artifact. Show a bounded stack excerpt per
  # process so a macOS sample's binary images cannot crowd out the call graph.
  for process in "$pid" $(descendants "$pid"); do
    echo "===== $(ps -o pid=,command= -p "$process" | cut -c1-200)"
    if command -v sample >/dev/null; then
      sample "$process" 3 2>&1
    elif command -v gdb >/dev/null; then
      gdb -p "$process" -batch -ex 'thread apply all bt' 2>&1
    fi
  done | tee -a "$log" | LC_ALL=C awk '
    /^===== / { process_bytes = 0; images = 0 }
    /^[[:space:]]*Binary Images:/ { images = 1 }
    !images && process_bytes < 16384 && total_bytes < 131072 {
      limit = 16384 - process_bytes
      if (131072 - total_bytes < limit) limit = 131072 - total_bytes
      line = substr($0, 1, limit - 1)
      print line
      process_bytes += length(line) + 1
      total_bytes += length(line) + 1
    }
  '
  descendants "$pid" | xargs kill -9 2>/dev/null
  kill -9 "$pid" 2>/dev/null
  exit 124
done
wait "$pid"
status=$?
if [ "$buffer_output" = true ]; then
  if [ "$status" -eq 0 ]; then
    emit_bounded_excerpt 0 80 0 32768
  else
    emit_bounded_excerpt 80 320 65536 131072
  fi
fi
exit "$status"
