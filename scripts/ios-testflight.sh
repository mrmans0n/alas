#!/usr/bin/env bash
# Archives the iOS app (Release: io.nlopez.alas, production push) and uploads
# it to App Store Connect for TestFlight.
#
# Needs DEVELOPMENT_TEAM (in the environment or Config/AlasMobile-Local.xcconfig)
# and either an Apple ID signed in to Xcode (Settings > Accounts) or an App
# Store Connect API key in ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID.
#
# Usage: scripts/ios-testflight.sh [--no-upload]
# --no-upload exports the .ipa to .build/ios-testflight/<build>/export instead;
# CI uploads that with fastlane (Mobile/fastlane/Fastfile).
set -euo pipefail

cd "$(dirname "$0")/.."
upload=1
[[ "${1:-}" == "--no-upload" ]] && upload=0

team=${DEVELOPMENT_TEAM:-$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/AlasMobile-Local.xcconfig 2>/dev/null | tr -d '[:space:]')}
if [[ -z "$team" || "$team" == YOURTEAMID ]]; then
  echo "Set DEVELOPMENT_TEAM in Config/AlasMobile-Local.xcconfig first." >&2
  exit 1
fi

auth=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

# Every upload needs a build number above the last; a UTC timestamp always is.
build=$(date -u +%Y%m%d%H%M)
out=.build/ios-testflight/$build
mkdir -p "$out"

xcodebuild -project Mobile/AlasMobile.xcodeproj -scheme AlasMobile -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/Alas.xcarchive" \
  -skipPackagePluginValidation \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
  DEVELOPMENT_TEAM="$team" CURRENT_PROJECT_VERSION="$build" archive

cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$([[ $upload == 1 ]] && echo upload || echo export)</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$out/Alas.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}

if [[ $upload == 1 ]]; then
  echo "Uploaded build $build. It shows in TestFlight once App Store Connect finishes processing."
else
  echo "Exported build $build to $out/export."
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  # The next CI step reads the build number and the exported .ipa from here.
  { echo "build=$build"; echo "ipa=$PWD/$out/export/Alas.ipa"; } >> "$GITHUB_OUTPUT"
fi
