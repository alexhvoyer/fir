#!/bin/sh
# Builds Release with development signing and installs it on a phone: ./scripts/install-device.sh
# Reads FIR_DEVICE and the optional App Store Connect key from .claude/local.env.
set -eu
cd "$(dirname "$0")/.."

if [ -f .claude/local.env ]; then . ./.claude/local.env; fi
: "${FIR_DEVICE:?Set FIR_DEVICE to the phone identifier from: xcrun devicectl list devices}"
set --
if [ -n "${ASC_KEY_ID:-}" ]; then
    set -- -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
fi

build="$(date +%Y%m%d).$(date +%H%M)"
xcodegen generate --quiet
mkdir -p build
if ! xcodebuild build -project Fir.xcodeproj -scheme Fir -configuration Release \
    -destination generic/platform=iOS -derivedDataPath build/device \
    -allowProvisioningUpdates "$@" CURRENT_PROJECT_VERSION="$build" > build/device.log 2>&1; then
    grep -aE "error:" build/device.log | head -20
    exit 1
fi
xcrun devicectl device install app --device "$FIR_DEVICE" build/device/Build/Products/Release-iphoneos/Fir.app
xcrun devicectl device info apps --device "$FIR_DEVICE" --bundle-id dev.khvoynitsky.browser | tail -1
echo "Installed build $build."
