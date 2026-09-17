#!/usr/bin/env bash
set -euo pipefail

exec ruby "$(dirname "$0")/test-build-workflow.rb"
