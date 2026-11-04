# Shipping Fir to TestFlight

Everything in the repo is ready for an upload. What remains needs a paid Apple Developer Program
membership and decisions only the account holder can make.

## 1. Developer Program

The signing team, `28MK6UC4T4`, is enrolled in the paid program as an Individual (renews November
2027). Enrolling turned the former Personal Team into the paid one, so its ID did not change.

## 2. App record

In App Store Connect, open Apps and choose New App:

- Platform: iOS
- Name: Fir Browser. App Store names are unique, and plain "Fir" is too short to stand out next to
  Firefox in search; the home screen shows the display name, Fir.
- Bundle ID: `dev.khvoynitsky.browser`. It names no product, so it survives a rename. Xcode registers it
  with the first automatic-signing build.
- SKU: any string, for example `xen-ios`.

## 3. Upload

```sh
./scripts/testflight.sh
```

The script archives a Release build, numbers it by date and time, and uploads it. After about 15
minutes of processing, the build appears under TestFlight.

Encryption is answered in `project.yml` as `ITSAppUsesNonExemptEncryption: false`, so builds skip the
question. Fir uses standard algorithms beyond Apple's own: the Rust components bundle NSS, which decrypts
Firefox Sync data (AES, HMAC). That needs no documentation unless the app is distributed in France, which
requires a French encryption declaration first; leave France out of availability until then.

## 4. Testers

- **Internal group**: up to 100 people, no review. Each tester must be a user on your App Store
  Connect team.
- **External group**: up to 10,000 people, invited by email or a public link. The first build
  goes through Beta App Review; later builds of the same version usually skip it.

To share with a friend, use an external group with a public link. Builds expire after 90 days.

### Test information (external testing)

Beta App Description:

> Fir is an independent app, not affiliated with Zen or Mozilla. It is a WebKit browser that syncs
> with Zen Browser through your Mozilla account: see the tabs open on your computer, open your Zen
> workspaces, essentials and pinned tabs, and send tabs back. It blocks ads and trackers with filter
> lists you choose, has HTTPS-Only mode, private tabs locked with Face ID, and a reader view.

Keep Zen out of the name, subtitle and keywords, and keep the disclaimer in the first line, as Z-Sync
does on the App Store. Mention Zen only as what Fir works with.

What to Test:

> Browse as usual and send feedback from TestFlight. Try the tab switcher, swiping between
> workspaces, and the page menu (long press the address). Signing in with a Mozilla account is
> optional and shows tabs from Zen or Firefox on your other devices.

Review notes:

> Sign-in is optional; every browsing feature works without it. Sync features need a Mozilla
> account with Zen or Firefox signed in on another device.

Feedback email: required; use the address you want feedback sent to.

## 5. Privacy

`Fir/PrivacyInfo.xcprivacy` declares the required-reason APIs found with `nm -u` in the app,
Glean and the Mozilla Rust components: UserDefaults, file timestamps, system boot time and disk
space. If App Store Connect emails an ITMS-91053 warning after an upload, add what it names there.

Glean is bundled but never started, so Fir sends nothing to its developer. For the App Store
privacy label that means "Data Not Collected". The Mozilla account sign-in goes to Mozilla, under
Mozilla's privacy policy.

The App Store requires a privacy policy URL; TestFlight may ask for one too. A draft to host
anywhere, such as a GitHub gist:

> Fir does not collect, store or share personal data with its developer. Browsing history, tabs
> and settings stay on your device. If you sign in with a Mozilla account, Fir syncs with
> Mozilla's servers under Mozilla's privacy policy. Websites you visit may collect data under
> their own policies.

## 6. Default browser

The entitlement is `com.apple.developer.web-browser`. Request it with the form at
developer.apple.com/contact/request/default-browser-entitlement/, signed in to the paid team.

Apple's requirements, and where Fir stands:

- HTTP and HTTPS schemes in `Info.plist`: declared in `project.yml`.
- No UIWebView: Fir uses WKWebView.
- At launch, a field for a URL or search: the address bar.
- Links open straight at their destination: `BrowserModel.openLink` opens a new tab in front and
  closes search if it is open.
- None of the forbidden `Info.plist` keys (full photo library, location always, HomeKit,
  Bluetooth always, Health): Fir uses none.

After approval:

1. Enable the capability for the App ID in Xcode's Signing & Capabilities. New profiles then
   include it, TestFlight builds too.
2. Add the entitlement to the app target in `project.yml`, so `xcodegen` keeps it.
3. Update the footer under Default Browser in `SettingsView.swift`, which says the build lacks the
   entitlement.

## 7. Mozilla OAuth client

Sync signs in with Firefox for iOS's public OAuth client ID (`AccountService.clientID`). The README
says so: it works for a personal build, but sharing the app with other people means distributing
Mozilla's client. Mozilla can revoke it at any time, and it does not issue Sync clients to third
parties. Decide whether that is acceptable before inviting testers.
