#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
device_id="${1:-${IPHONE_ID:-}}"
if [[ -z "$device_id" ]]; then
  echo 'Usage: scripts/install-iphone.sh DEVICE_ID. Find it with: xcrun devicectl list devices' >&2
  exit 2
fi
mkdir -p artifacts
xcodebuild -project ios/BetterPlex.xcodeproj -scheme BetterPlex \
  -destination 'generic/platform=iOS' -derivedDataPath .build-device \
  -allowProvisioningUpdates build > artifacts/build-device.log 2>&1 || {
    tail -30 artifacts/build-device.log
    exit 1
  }
app_path='.build-device/Build/Products/Debug-iphoneos/BetterPlex.app'
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Info.plist")
xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch --device "$device_id" "$bundle_id"
