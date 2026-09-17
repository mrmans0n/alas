#!/usr/bin/env bash
set -euo pipefail

this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B -m unittest discover -s "${this_dir}" -p 'test_*.py'

echo "swift test inventory tests passed"
