#!/usr/bin/env bash
set -euo pipefail

# Notarizes a DMG with Apple's notary service and staples the returned
# ticket onto it. The .app inside the DMG must already be signed —
# Apple's notary verifies the signed contents, not the DMG container.
# A separate codesign on the DMG itself is therefore not required.
#
# Usage: scripts/notarize-and-staple-dmg.sh <path-to-dmg>
#
# Required env vars:
#   MACOS_NOTARY_APPLE_ID     — Apple Developer account email
#   MACOS_NOTARY_APP_PASSWORD — app-specific password (appleid.apple.com)
#   MACOS_NOTARY_TEAM_ID      — 10-character Apple Team ID

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <path-to-dmg>" >&2
  exit 2
fi

dmg_path="$1"

if [ ! -f "$dmg_path" ]; then
  echo "error: $dmg_path does not exist" >&2
  exit 1
fi

missing=0
for var in MACOS_NOTARY_APPLE_ID MACOS_NOTARY_APP_PASSWORD MACOS_NOTARY_TEAM_ID; do
  if [ -z "${!var:-}" ]; then
    echo "error: env var $var is not set" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

tmp_root="${RUNNER_TEMP:-$(mktemp -d -t alas-dmg-notary)}"
mkdir -p "$tmp_root"
notary_log="$tmp_root/notary-dmg-submit.log"

echo "==> Submitting $dmg_path to notary"
set +e
xcrun notarytool submit "$dmg_path" \
  --apple-id "$MACOS_NOTARY_APPLE_ID" \
  --password "$MACOS_NOTARY_APP_PASSWORD" \
  --team-id "$MACOS_NOTARY_TEAM_ID" \
  --wait \
  --timeout 30m \
  --output-format json \
  > "$notary_log" 2>&1
notary_rc=$?
set -e
cat "$notary_log"

submission_id="$(jq -r '.id // empty' "$notary_log" 2>/dev/null || true)"
status="$(jq -r '.status // empty' "$notary_log" 2>/dev/null || true)"

if [ "$notary_rc" -ne 0 ] || [ "$status" != "Accepted" ]; then
  echo "error: DMG notarization failed (rc=$notary_rc, id=$submission_id, status=$status)" >&2
  if [ -n "$submission_id" ]; then
    echo "==> Fetching notarytool log for submission $submission_id" >&2
    xcrun notarytool log "$submission_id" \
      --apple-id "$MACOS_NOTARY_APPLE_ID" \
      --password "$MACOS_NOTARY_APP_PASSWORD" \
      --team-id "$MACOS_NOTARY_TEAM_ID" >&2 || true
  fi
  exit 1
fi

echo "==> Stapling ticket onto DMG"
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"

echo "==> Done. $dmg_path is notarized and stapled."
