#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
chmod +x fixtures/stub-zig.sh test_*.sh
fails=0
for t in test_*.sh; do
  printf '== %-50s ' "${t}"
  if "./${t}" >"${t}.log" 2>&1; then
    echo PASS
  else
    echo FAIL
    sed 's/^/    /' "${t}.log"
    fails=$((fails + 1))
  fi
done
[ ${fails} -eq 0 ] || { echo "${fails} test(s) failed" >&2; exit 1; }
echo "all tests passed"
