#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap teardown_sandbox EXIT

setup_sandbox

counter="${SANDBOX}/build-count"
echo 0 > "${counter}"
cat > "${SANDBOX}/flaky-zig.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
n=\$(cat "${counter}")
n=\$((n + 1))
echo "\${n}" > "${counter}"
if [ "\${n}" -lt 3 ]; then
  echo "flaky-zig: simulated 504" >&2
  exit 1
fi
exec "${STUB_ZIG}" "\$@"
EOF
chmod +x "${SANDBOX}/flaky-zig.sh"

run_build_script \
  ALAS_ZIG_BIN="${SANDBOX}/flaky-zig.sh" \
  ALAS_GHOSTTY_RETRY_DELAYS="0 0" \
    >"${SANDBOX}/out" 2>"${SANDBOX}/err"

assert_eq "$(cat "${counter}")" "3" "zig retried until the third attempt"
assert_eq "$(stub_invocations)" "1" "final successful attempt delegated to stub"
grep -q "retrying in 0s (attempt 2/3)" "${SANDBOX}/err" \
  || fail "missing first retry warning"
grep -q "retrying in 0s (attempt 3/3)" "${SANDBOX}/err" \
  || fail "missing second retry warning"
assert_dir_exists "${SRCROOT}/.build/ghostty/GhosttyKit.xcframework"

