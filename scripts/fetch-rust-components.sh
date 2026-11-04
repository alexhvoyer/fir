#!/bin/sh
# Downloads Mozilla's Rust components xcframework and adds the Info.plist its framework
# slices lack. Xcode embeds the framework stub regardless, and app validation rejects it without one.
# App Store Connect also wants MinimumOSVersion to match the stub, linked at the app's deployment
# target, and a CFBundleVersion of at most 18 characters.
set -eu

VERSION="160.0.20261022050218"
URL="https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/project.application-services.v2.swift.160.20261022050218/artifacts/public/build/MozillaRustComponents.xcframework.zip"
SHA256="52319c047975fd350bcc0678606874eb3169c8f6f4caaef95db1f5fb1fc28c65"

DEST="$(cd "$(dirname "$0")/.." && pwd)/Packages/MozillaRustComponents"
XCF="$DEST/MozillaRustComponents.xcframework"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MIN_OS="$(sed -n 's/^ *iOS: "\(.*\)"$/\1/p' "$DEST/../../project.yml")"

curl -fL --progress-bar -o "$TMP/rc.zip" "$URL"
echo "$SHA256  $TMP/rc.zip" | shasum -a 256 -c -
rm -rf "$XCF"
unzip -q "$TMP/rc.zip" -d "$TMP"
mv "$TMP/MozillaRustComponents.xcframework" "$XCF"

for fw in "$XCF"/*/MozillaRustComponents.framework; do
  cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MozillaRustComponents</string>
  <key>CFBundleIdentifier</key><string>org.mozilla.MozillaRustComponents</string>
  <key>CFBundleName</key><string>MozillaRustComponents</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${VERSION%%.*}.0</string>
  <key>CFBundleVersion</key><string>${VERSION%%.*}.0</string>
  <key>MinimumOSVersion</key><string>${MIN_OS}</string>
</dict>
</plist>
EOF
done
echo "Installed $XCF"
