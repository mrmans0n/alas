#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
bash "${script_dir}/test_buffered_output.sh"
echo "stall watchdog harness: ok"
