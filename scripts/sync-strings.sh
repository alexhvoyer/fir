#!/bin/sh
# Copies the strings the last simulator build found in the code into the string catalogs: ./scripts/sync-strings.sh
# Xcode does this on its own builds; xcodebuild only extracts them. Pass another derived data folder as $1.
set -eu
cd "$(dirname "$0")/.."

builds="${1:-build/uitests}/Build/Intermediates.noindex/Fir.build"
for target in Fir FirWidget FirShare; do
    data="$(find "$builds" -path "*/$target.build/Objects-normal/*" -name '*.stringsdata' 2>/dev/null)"
    if [ -z "$data" ]; then
        echo "No build of $target under $builds: build for a simulator first." >&2
        exit 1
    fi
    printf '%s\n' "$data" | tr '\n' '\0' | xargs -0 xcrun xcstringstool sync "$target/Localizable.xcstrings" --stringsdata
done

# Info.plist strings aren't extracted from the command line: InfoPlist.xcstrings is kept by hand.
for key in $(grep -oE 'INFOPLIST_KEY_NS[A-Za-z]+UsageDescription' project.yml | sed 's/INFOPLIST_KEY_//'); do
    grep -q "\"$key\"" Fir/InfoPlist.xcstrings || echo "Add $key to Fir/InfoPlist.xcstrings." >&2
done
echo "Synced $(xcrun xcstringstool print Fir/Localizable.xcstrings | grep -c .) app and $(xcrun xcstringstool print FirWidget/Localizable.xcstrings | grep -c .) widget lines."
