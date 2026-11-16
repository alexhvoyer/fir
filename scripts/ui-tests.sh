#!/bin/sh
# Runs the UI smoke tests (FirUITests) on a simulator of their own: ./scripts/ui-tests.sh
# The simulator is erased first, so it is never signed in and its tabs never sync to a real account.
set -eu
cd "$(dirname "$0")/.."

name="Fir UI Tests"
device="$(xcrun simctl list devices | grep "$name (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)"
if [ -z "$device" ]; then
    # The newest iPhone Pro, on the newest iOS that supports it.
    pick="$(xcrun simctl list runtimes --json | python3 -I -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
for runtime in sorted(runtimes, key=lambda r: [int(p) for p in r["version"].split(".")], reverse=True):
    pros = [t for t in runtime["supportedDeviceTypes"] if t["name"].startswith("iPhone") and t["name"].endswith(" Pro")]
    if pros:
        newest = max(pros, key=lambda t: int(t["name"].split()[1]))
        print(newest["identifier"], runtime["identifier"])
        break
')"
    device="$(xcrun simctl create "$name" ${pick})"
fi
xcrun simctl shutdown "$device" 2>/dev/null || true
xcrun simctl erase "$device"

xcodegen generate --quiet
mkdir -p build
if ! xcodebuild test -project Fir.xcodeproj -scheme FirUITests -destination "id=$device" \
    -derivedDataPath build/uitests > build/ui-tests.log 2>&1; then
    grep -aE "error:|failed|XCTAssert|✘" build/ui-tests.log | head -40
    echo "UI tests failed. Full log: build/ui-tests.log"
    exit 1
fi
grep -aE "Executed [0-9]+ tests?" build/ui-tests.log | tail -1
echo "UI tests passed on $name ($device)."
