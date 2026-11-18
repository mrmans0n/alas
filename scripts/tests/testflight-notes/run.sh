#!/bin/bash
set -euo pipefail
ruby "$(dirname "$0")/test_testflight_notes.rb"
