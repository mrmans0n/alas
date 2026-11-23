#!/usr/bin/env bash
set -euo pipefail
node "$(dirname "$0")/test-peer-console.js"
node "$(dirname "$0")/test-terminals.js"
