#!/usr/bin/env bash
set -euo pipefail

# Removes the ephemeral signing keychain created by sign-and-notarize.sh.
# Idempotent: exits 0 even if the keychain doesn't exist. Safe to run with
# `if: always()` in CI so a failed signing job still leaves no .p12 residue
# on the runner.

kc_dir="${RUNNER_TEMP:-/tmp}"
kc_path="$kc_dir/signing.keychain-db"

if [ ! -f "$kc_path" ]; then
  echo "No signing keychain at $kc_path; nothing to clean."
  exit 0
fi

# Drop from search list. `security list-keychains -d user` quotes each path;
# strip the quotes, grep out our keychain, pass the remainder back as the
# new search list. If grep removes the only entry, `security` accepts an
# empty list and falls back to the system default.
remaining="$(security list-keychains -d user \
  | tr -d '"' \
  | awk -v skip="$kc_path" '$0 != skip' \
  | xargs)"
# shellcheck disable=SC2086
security list-keychains -d user -s $remaining

security delete-keychain "$kc_path" || true
rm -f "$kc_path"

echo "Removed signing keychain at $kc_path."
