#!/usr/bin/env bash
set -euo pipefail

# Signs, notarizes, and staples a built Alas.app bundle. Invoked by
# .github/workflows/release.yml and nightly.yml between the xcodebuild
# step and package-app.sh. Runs locally too if the same env vars are set —
# useful for debugging notarization rejections without burning CI minutes.
#
# Usage: scripts/sign-and-notarize.sh <path-to-Alas.app>
#
# Required env vars (all six):
#   MACOS_CERTIFICATE_P12_BASE64 — base64-encoded Developer ID .p12 blob
#   MACOS_CERTIFICATE_PASSWORD   — password for the .p12
#   MACOS_SIGNING_IDENTITY       — cert Common Name, e.g.
#                                  "Developer ID Application: Nacho Lopez (TEAMID1234)"
#   MACOS_NOTARY_APPLE_ID        — Apple Developer account email
#   MACOS_NOTARY_APP_PASSWORD    — app-specific password (appleid.apple.com)
#   MACOS_NOTARY_TEAM_ID         — 10-character Apple Team ID

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <path-to-Alas.app>" >&2
  exit 2
fi

app_path="$1"

if [ ! -d "$app_path" ]; then
  echo "error: $app_path is not a directory" >&2
  exit 1
fi

# Validate env. Print every missing var, not just the first — saves a
# round-trip when several aren't set on a developer's mac.
missing=0
for var in \
  MACOS_CERTIFICATE_P12_BASE64 \
  MACOS_CERTIFICATE_PASSWORD \
  MACOS_SIGNING_IDENTITY \
  MACOS_NOTARY_APPLE_ID \
  MACOS_NOTARY_APP_PASSWORD \
  MACOS_NOTARY_TEAM_ID; do
  if [ -z "${!var:-}" ]; then
    echo "error: env var $var is not set" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
entitlements="$repo_root/Alas/Resources/Alas.entitlements"

if [ ! -f "$entitlements" ]; then
  echo "error: entitlements file not found at $entitlements" >&2
  exit 1
fi

# All temp state goes in $RUNNER_TEMP on CI, or a fresh mktemp dir locally.
tmp_root="${RUNNER_TEMP:-$(mktemp -d -t alas-sign)}"
mkdir -p "$tmp_root"
kc_path="$tmp_root/signing.keychain-db"
kc_password="$(uuidgen)"
p12_path="$tmp_root/cert.p12"
notary_zip="$tmp_root/notary.zip"

# Clean up only the per-run temp files (not the keychain — cleanup script
# handles that in its own CI step so it runs even if we exit non-zero
# before the trap fires).
trap 'rm -f "$p12_path" "$notary_zip"' EXIT

echo "==> Creating ephemeral keychain at $kc_path"
security create-keychain -p "$kc_password" "$kc_path"
security set-keychain-settings -lut 21600 "$kc_path"
security unlock-keychain -p "$kc_password" "$kc_path"

echo "==> Decoding .p12"
echo "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$p12_path"

echo "==> Importing .p12 into keychain"
security import "$p12_path" \
  -k "$kc_path" \
  -P "$MACOS_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign

# Authorize codesign to use the key without UI prompt. Required since
# macOS 10.12; without this, codesign hangs forever in headless CI
# waiting for a "Always Allow" dialog.
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$kc_password" "$kc_path" >/dev/null

# Prepend the new keychain to the search list. codesign needs the key
# in a keychain that's on the search list; the default search list
# doesn't include our temp keychain until we add it explicitly.
existing="$(security list-keychains -d user | tr -d '"' | xargs)"
# shellcheck disable=SC2086
security list-keychains -d user -s "$kc_path" $existing

echo "==> Asserting signing identity is present"
if ! security find-identity -v -p codesigning "$kc_path" \
   | grep -F "$MACOS_SIGNING_IDENTITY" >/dev/null; then
  echo "error: signing identity '$MACOS_SIGNING_IDENTITY' not found in imported .p12" >&2
  echo "Identities present in keychain:" >&2
  security find-identity -v -p codesigning "$kc_path" >&2
  exit 1
fi

# Standalone executables embedded under Resources are not treated as nested code
# by `codesign --deep`, so sign them explicitly before sealing the app bundle.
zmx_path="$app_path/Contents/Resources/zmx/zmx"
if [ -x "$zmx_path" ]; then
  echo "==> Signing embedded zmx helper"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$MACOS_SIGNING_IDENTITY" \
    "$zmx_path"
  codesign --verify --strict --verbose=2 "$zmx_path"
fi

echo "==> Signing $app_path"
codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --entitlements "$entitlements" \
  --sign "$MACOS_SIGNING_IDENTITY" \
  "$app_path"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$app_path"

# Note: we deliberately skip `spctl --assess` here. Pre-staple, spctl
# results depend on Apple's online ticket cache and are inconsistent;
# the answer doesn't change whether we proceed. spctl validation happens
# post-merge against the published artifact (see spec test plan).

echo "==> Packaging .app into notary zip"
ditto -c -k --keepParent "$app_path" "$notary_zip"

echo "==> Submitting to notary"
# notarytool's --wait blocks until Apple returns; --timeout caps the
# wait at 30 min. --output-format json emits a single compact JSON
# object on the final line — parsed with jq below.
notary_log="$tmp_root/notary-submit.log"
set +e
xcrun notarytool submit "$notary_zip" \
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
  echo "error: notarization failed (rc=$notary_rc, id=$submission_id, status=$status)" >&2
  if [ -n "$submission_id" ]; then
    echo "==> Fetching notarytool log for submission $submission_id" >&2
    xcrun notarytool log "$submission_id" \
      --apple-id "$MACOS_NOTARY_APPLE_ID" \
      --password "$MACOS_NOTARY_APP_PASSWORD" \
      --team-id "$MACOS_NOTARY_TEAM_ID" >&2 || true
  fi
  exit 1
fi

echo "==> Stapling ticket onto .app"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

echo "==> Done. $app_path is signed, notarized, and stapled."
