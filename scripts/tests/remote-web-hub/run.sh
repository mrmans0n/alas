#!/usr/bin/env bash
set -euo pipefail
node "$(dirname "$0")/test-hub-registry.js"
node "$(dirname "$0")/test-hub-links.js"
