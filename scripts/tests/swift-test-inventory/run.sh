#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for test_script in "${this_dir}"/test_*.sh; do
    bash "${test_script}"
done

echo "swift test inventory tests passed"
