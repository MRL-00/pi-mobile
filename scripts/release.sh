#!/bin/bash
# Archive PiMobile and upload to TestFlight, non-interactively via the
# App Store Connect API key (no Apple ID sign-in / 2FA needed).
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID=Q62872XNN8
ISSUER_ID=a3f9067b-dd48-45c5-ac8d-f78f15d3a4cb
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$KEY_ID"
      -authenticationKeyIssuerID "$ISSUER_ID")

xcodebuild -project PiMobile.xcodeproj -scheme PiMobile -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/PiMobile.xcarchive archive "${AUTH[@]}"

# exportOptions.plist has destination=upload, so this exports AND uploads.
xcodebuild -exportArchive \
  -archivePath build/PiMobile.xcarchive \
  -exportOptionsPlist build/exportOptions.plist "${AUTH[@]}"

echo "Uploaded. Check TestFlight processing at https://appstoreconnect.apple.com"
