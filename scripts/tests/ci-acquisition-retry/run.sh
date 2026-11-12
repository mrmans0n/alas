#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
bash "${script_dir}/test_retry.sh"
echo "ci acquisition retry harness: ok"
