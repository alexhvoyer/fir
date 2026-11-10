---
name: fir-install
description: Build Fir and put it on the phone, or upload it to TestFlight with the argument "testflight".
disable-model-invocation: true
---

# Install Fir

The argument is `$ARGUMENTS`. Run the script in the background: a build takes minutes.

- No argument: `./scripts/install-device.sh`. It needs the phone connected and unlocked. If `devicectl` cannot reach
  it, ask for a cable and an unlocked screen, then run only the `devicectl device install` line again.
- `testflight`: `./scripts/testflight.sh`. `xcodebuild -exportArchive` can exit 0 after a failed upload, so report
  success only when the output contains `Upload succeeded`.

Report the build number and what was not checked. Never open the `.p8` file in `.claude/local.env`.
