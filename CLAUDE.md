# Fir

A WebKit browser for iPhone that syncs with Zen and Firefox. SwiftUI, iOS 26 and later; features from newer
systems sit behind `#available`.

## Layout

- `Fir/` the app, `FirWidget/` widgets, controls and Live Activities, `Shared/` compiled into both.
- `project.yml` is the source of the Xcode project and `Fir/Info.plist`. `Fir.xcodeproj` is generated and ignored.
- Run `xcodegen generate` after changing `project.yml` or adding a file.
- `Packages/MozillaRustComponents` is generated Mozilla code. Leave it alone.
- There is no test target. Changes are verified on the simulator and, for feel, on a phone.

## Commands

```sh
xcodegen generate
xcodebuild -project Fir.xcodeproj -scheme Fir -destination "id=<simulator>" -derivedDataPath build/sim build
xcrun simctl install <simulator> build/sim/Build/Products/Debug-iphonesimulator/Fir.app
xcrun simctl launch --terminate-running-process <simulator> dev.khvoynitsky.browser
```

`/fir-install` builds for a phone or uploads to TestFlight. `/animation-check` measures an animation from a recording.

## Working rules

- Build UI, transitions and effects from system components: sheets, zoom transitions, Form, List, Menu, glass.
  Draw something custom only when nothing native exists, and say so.
- Never commit, push, upload to TestFlight or install on a phone unless asked. Several ideas often share one build.
- After a verification build, leave the final build on the simulator, not a control build.
- Code, comments and docs are in English. A comment block is at most 30 words and explains why.
- Temporary test code must contain `dbg` or `DBG`, so the commit hook can catch what was left behind.
- Open a saved API key file only through `xcodebuild`; never read it.

## Security invariants

Do not undo these. `fir-security-reviewer` checks a change against them.

- `pageURL` follows a URL change only when it is same-origin; a cross-origin URL waits for `didCommit`. The address
  bar and `ConnectionReport` read the committed value. Every path that starts a load sets `requestedURL`.
- The app lock lives in its own `UIWindow` above sheets. Turning a lock off needs Face ID.
- Only the main frame may open another app, after a `PageDialog`. A tapped `tel`, `facetime`, `mailto` or `sms` link
  skips the dialog.
- Autofill runs its `location.origin === origin` check in the same `callAsyncJavaScript` call as the fill.
- Private tabs leave nothing on disk and nothing outside the app: no session, snapshot, icon, history, Handoff or
  Live Activity. Extensions never see them. The one exception is a file the user downloads, which stays in Downloads.
- A Live Activity shows no file names or page text: a server chooses them, and the Lock Screen ignores Fir's lock.
- Text from the system, such as Spotlight or an intent, is always searched, never treated as an address.

## Behaviour worth knowing

- `open(_:in: nil)` means this iPhone's tabs; `open(_:)` means the workspace on screen.
- Deck transitions carry `transitionID`; a completion from an older transition stands aside.
- During a released swipe `swipeX` already holds its target. Anything derived from it sees the end value unless it
  animates: do not branch view structure on it.
- Glass inside a `GlassEffectContainer` draws even at zero width, and a mask has no effect on it.
- Sign-out wipes local passwords and history, then disconnects sync, in that order: disconnecting drops anything the
  wipes queued for upload, so the deletions cannot reach the account.
- `BrowserTab.isBlank` drops one-colour snapshots that WebKit returns on real phones. Keep it.

## Simulator testing traps

- Launch arguments set defaults. For a Bool read through `bool(forKey:default:)` pass `-key '<false/>'`: plain `NO`
  arrives as a string and reads as unset. `simctl spawn defaults` writes to another domain and changes nothing.
- JIT seems to be off in the simulator, so script-speed comparisons mean nothing there.
- Test sign-in and scheme behaviour on pages served from `127.0.0.1`.
- Face ID: `xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit_Sim.pearl.match`, or `.nomatch`.
- Control Center puts a control in a different place than its edit mode does. Take a screenshot before tapping.
