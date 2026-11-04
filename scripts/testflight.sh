#!/bin/sh
# Archives Fir in Release and uploads it to App Store Connect for TestFlight: ./scripts/testflight.sh
# Needs a paid Developer Program team signed in under Xcode > Settings > Accounts, set in project.yml.
set -eu
cd "$(dirname "$0")/.."

# Every upload needs a build number above the last one; the date and time always are.
build="$(date +%Y%m%d).$(date +%H%M)"
xcodegen generate
rm -rf build/Fir.xcarchive build/export
xcodebuild archive -project Fir.xcodeproj -scheme Fir -configuration Release \
    -destination generic/platform=iOS -archivePath build/Fir.xcarchive \
    -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build"
xcodebuild -exportArchive -archivePath build/Fir.xcarchive -exportPath build/export \
    -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates
echo "Uploaded build $build. It shows in App Store Connect > TestFlight after processing."
