#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
watchdog="${repo_root}/scripts/run-with-stall-watchdog.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

producer="${tmpdir}/producer.sh"
cat > "$producer" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${PRODUCER_STATUS:-0}" -ne 0 ]; then
  echo "FATAL-ROOT-CAUSE"
fi
for i in $(seq 1 5000); do
  printf 'line-%05d\n' "$i"
done
echo "producer complete"
exit "${PRODUCER_STATUS:-0}"
SCRIPT
chmod +x "$producer"

success_output="${tmpdir}/success.log"
"$watchdog" 30 --buffer-output "$producer" > "$success_output" 2>&1
grep -q '^producer complete$' "$success_output"
if grep -q '^line-00001$' "$success_output"; then
  echo "buffered success output leaked the full command log" >&2
  exit 1
fi
success_lines="$(wc -l < "$success_output")"
if [ "$success_lines" -gt 100 ]; then
  echo "buffered success output is not bounded: ${success_lines} lines" >&2
  exit 1
fi

failure_output="${tmpdir}/failure.log"
failure_complete_log="${tmpdir}/failure-complete.log"
set +e
PRODUCER_STATUS=7 "$watchdog" 30 --buffer-output --log-file "$failure_complete_log" "$producer" > "$failure_output" 2>&1
failure_status=$?
set -e
if [ "$failure_status" -ne 7 ]; then
  echo "expected producer status 7, got ${failure_status}" >&2
  exit 1
fi
grep -q '^FATAL-ROOT-CAUSE$' "$failure_output"
grep -q '^producer complete$' "$failure_output"
if grep -q '^line-02500$' "$failure_output"; then
  echo "buffered failure output leaked the full command log" >&2
  exit 1
fi
failure_lines="$(wc -l < "$failure_output")"
if [ "$failure_lines" -gt 420 ]; then
  echo "buffered failure output is not bounded: ${failure_lines} lines" >&2
  exit 1
fi
grep -q '^FATAL-ROOT-CAUSE$' "$failure_complete_log"
grep -q '^line-00001$' "$failure_complete_log"

giant_producer="${tmpdir}/giant-producer.sh"
cat > "$giant_producer" <<'SCRIPT'
#!/usr/bin/env bash
printf 'FATAL-GIANT:'
dd if=/dev/zero bs=1048576 count=2 2>/dev/null | tr '\0' x
printf '\n'
exit 9
SCRIPT
chmod +x "$giant_producer"
giant_output="${tmpdir}/giant-output.log"
giant_complete_log="${tmpdir}/giant-complete.log"
set +e
"$watchdog" 30 --buffer-output --log-file "$giant_complete_log" "$giant_producer" > "$giant_output" 2>&1
giant_status=$?
set -e
if [ "$giant_status" -ne 9 ]; then
  echo "expected giant producer status 9, got ${giant_status}" >&2
  exit 1
fi
giant_bytes="$(wc -c < "$giant_output")"
if [ "$giant_bytes" -gt 200000 ]; then
  echo "buffered failure output is not byte-bounded: ${giant_bytes} bytes" >&2
  exit 1
fi
complete_bytes="$(wc -c < "$giant_complete_log")"
if [ "$complete_bytes" -lt 2000000 ]; then
  echo "complete failure log was not retained: ${complete_bytes} bytes" >&2
  exit 1
fi

legacy_output="${tmpdir}/legacy-output.log"
set +e
"$watchdog" 30 bash -c 'echo legacy-stream; exit 6' > "$legacy_output" 2>&1
legacy_status=$?
set -e
if [ "$legacy_status" -ne 6 ]; then
  echo "expected legacy producer status 6, got ${legacy_status}" >&2
  exit 1
fi
grep -q '^legacy-stream$' "$legacy_output"

silent_producer="${tmpdir}/silent-producer.sh"
mock_bin="${tmpdir}/mock-bin"
mkdir -p "$mock_bin"
cat > "${mock_bin}/sample" <<'SCRIPT'
#!/usr/bin/env bash
echo "MOCK-SAMPLE pid=$1"
echo "Call graph:"
echo "    BLOCKED-TEST-FRAME"
echo "Binary Images:"
awk 'BEGIN { for (i = 0; i < 400; i++) print "MOCK-BINARY-IMAGE" }'
SCRIPT
chmod +x "${mock_bin}/sample"
cat > "$silent_producer" <<SCRIPT
#!/usr/bin/env bash
echo \$\$ > "${tmpdir}/silent-parent.pid"
sleep 300 &
echo \$! > "${tmpdir}/silent-child.pid"
wait
SCRIPT
chmod +x "$silent_producer"
stall_output="${tmpdir}/stall-output.log"
stall_complete_log="${tmpdir}/stall-complete.log"
set +e
PATH="${mock_bin}:$PATH" "$watchdog" 10 --buffer-output --log-file "$stall_complete_log" "$silent_producer" > "$stall_output" 2>&1
stall_status=$?
set -e
if [ "$stall_status" -ne 124 ]; then
  echo "expected stalled producer status 124, got ${stall_status}" >&2
  exit 1
fi
grep -q 'No output for 10s' "$stall_output"
grep -q '^===== ' "$stall_complete_log"
grep -q '^MOCK-SAMPLE pid=' "$stall_complete_log"
grep -q 'BLOCKED-TEST-FRAME' "$stall_output"
grep -q '^MOCK-BINARY-IMAGE$' "$stall_complete_log"
if grep -q '^MOCK-BINARY-IMAGE$' "$stall_output"; then
  echo "binary image listings displaced the sampled stacks" >&2
  exit 1
fi
for pid_file in "${tmpdir}/silent-parent.pid" "${tmpdir}/silent-child.pid"; do
  stalled_pid="$(cat "$pid_file")"
  if kill -0 "$stalled_pid" 2>/dev/null; then
    echo "stalled process ${stalled_pid} survived watchdog termination" >&2
    exit 1
  fi
done

legacy_stall_output="${tmpdir}/legacy-stall-output.log"
set +e
PATH="${mock_bin}:$PATH" "$watchdog" 10 bash -c 'sleep 300' > "$legacy_stall_output" 2>&1
legacy_stall_status=$?
set -e
if [ "$legacy_stall_status" -ne 124 ]; then
  echo "expected legacy stalled producer status 124, got ${legacy_stall_status}" >&2
  exit 1
fi
grep -q 'No output for 10s' "$legacy_stall_output"
grep -q '^MOCK-SAMPLE pid=' "$legacy_stall_output"

temporary_output="${tmpdir}/temporary-output.log"
set +e
PRODUCER_STATUS=7 "$watchdog" 30 --buffer-output "$producer" > "$temporary_output" 2>&1
temporary_status=$?
set -e
if [ "$temporary_status" -ne 7 ]; then
  echo "expected temporary buffered status 7, got ${temporary_status}" >&2
  exit 1
fi
if grep -q 'complete log retained at' "$temporary_output"; then
  echo "temporary buffered output falsely claimed its log was retained" >&2
  exit 1
fi

echo "stall watchdog buffered output: ok"
