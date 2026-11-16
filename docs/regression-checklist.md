# Regression checklist

Fir has almost no automated UI tests, so these checks are run by hand.

- Run **Smoke** before every TestFlight upload.
- After a change, run the sections it touches. The map below says which those are.
- When a bug is fixed, add a case for it under its area, marked **(was broken)**. That stops it coming back unseen.

Each case says where it needs to run:
- `sim`: the simulator is enough.
- `phone`: needs a real device (Face ID, feel, 120 Hz, the default-browser entitlement).

Tabs in a Zen workspace sync to the real account. Close tabs in tests only in Private or in this iPhone's tabs.

## Which sections to run

| Changed | Run |
| --- | --- |
| `BrowserView` transitions, swipes, bar | Page and bar, Swipes and lift, both tab overviews |
| `TabSwitcherView`, `TabGrid` | Both tab overviews, Workspaces |
| Sheets (`NewTabView`, `PageSheet`, settings) | Page and bar, Accessibility |
| Navigation, `BrowserModel`, links | Page and bar, Links in and out, Private and locks, then `fir-security-reviewer` |
| Sync, `ZenSpaces`, `AccountService` | Workspaces and sync |
| `PasswordAutofill`, `PasswordStore` | Passwords |
| `Extensions` | Add-ons |
| Onboarding, What's New, settings | Onboarding and settings |

## Smoke

`scripts/ui-tests.sh` runs steps 1 to 6 and 8, the start-page search in the bar, Undo of a blank tab and quick grid
closes with an early Undo, as `FirUITests`, on an erased simulator of its own with local test
pages. `scripts/testflight.sh` runs it before every upload. Step 7 needs a signed-in account, so it stays a manual
check on the signed-in simulator. Run the whole list by hand when a change touches what a test can't see: feel,
timing, sync.

1. Cold launch: the last page shows its snapshot, then goes live with no white flash.
2. Tap the address bar: search opens with the keyboard. Type a query and press Return: the page loads in the same
   workspace.
3. Swipe the bar left and right to switch tabs, then swipe up to the tab overview. Open a different tab from there.
4. Do step 3 once with Cards and once with Grid (Settings > Tabs > Tab Overview).
5. Open the page menu, then close it. Lift straight away to the tab overview. Nothing is left floating over the
   switcher.
6. Open a private tab (long-press the tabs button). Close it from the overview.
7. Switch workspaces with the bottom switcher. The Zen folders and essentials of each workspace show.
8. Open Settings and close it. Open Share on a page and close it.

## Page and bar

- `sim` The address bar shows the committed host. While a cross-origin page loads, it keeps the old one.
- `sim` Search sheet from the bar grows out of the address capsule. With Reduce Motion it slides up as a plain sheet.
- `sim` With New Tab set to Start Page, tapping the address puts the field in the bar's place with no sheet; it rides
  up on the keyboard. Cancel, or putting the keyboard away, brings the bar back. Landscape still uses the sheet.
- `sim` **(was broken)** Start Page mode: Cancel or Return takes the keyboard down with the field riding on it, then the
  field fades into the bar. Removed at once, both vanished in one frame.
- `sim` Start Page mode on a blank tab: while the field is up, the tab's own start page shows behind it and its tiles
  open in the tab.
- `phone` Start Page mode: the keyboard comes up as fast as in Safari (FrameMeter stall well under the sheet's).
- `sim` Page menu grows out of the menu button or the address. With Reduce Motion it slides up.
- `sim` **(was broken)** Close the page menu and lift to the tab overview at once. The address capsule must not stay
  over the switcher.
- `sim` **(was broken)** With an add-on installed, the bar's buttons don't overlap the address text.
- `sim` The bar collapses on scroll and expands on tap or when a new page starts loading.
- `phone` Scrolling a long page stays smooth (FrameMeter: about 115 fps at 120 Hz).

## Swipes and lift

- `sim` Swipe the bar sideways to move to the next and previous tab. Past the last tab a new tab slides in.
- `sim` Call off a swipe halfway: the page returns and the tab doesn't change.
- `sim` Lift the page with the bar into the tab overview. Fling it back down to call it off.
- `sim` A second swipe during the first one's landing still counts.
- `sim` Edge swipe goes back and forward in history, using WebKit's own gesture.

## Tab overview: Cards

- `sim` Swipe the deck sideways. Swipe a card up to close it. Pull a card down to open it.
- `sim` Tap a card: the page grows out of it. Close the page: it shrinks back onto the same card.
- `sim` A Zen folder shows as a stack. Tap it to fan it out. Its title menu collapses it again.
- `sim` A card's title menu offers pin, essentials and folder actions, and close.
- `sim` After a cold launch, a tab not opened yet loads when its card is tapped or it is swiped to, with its bar buttons.
  Restored tabs get their web view only then; closing one that never loaded works and Undo brings it back.
- `sim` **(was broken)** Close a blank tab and tap Undo with Recently Closed empty: the tab comes back. It crashed.
- `sim` **(was broken)** Signed in, with a Zen folder in the workspace: quit Fir, open it, and tap the tabs button at once.
  The page shrinks straight onto its card. The sync's new layout used to send it one card aside first.

## Tab overview: Grid

- `sim` The page grows out of its cell and shrinks back into it, landing exactly on the cell.
- `sim` **(was broken)** After closing a page, its cell shows its picture and the selected outline. A LazyVGrid kept
  the picture hidden.
- `sim` Swipe a cell left past a third of its width: it slides off and closes. A shorter swipe returns it.
- `sim` A flick back to the right keeps the tab, however far the cell went.
- `sim` A cell dragged right follows with growing resistance and springs back; it never closes that way.
- `sim` A finger on a cell lifts it a little; scrolling or lifting the finger settles it back. The long-press menu still opens.
- `sim` The close button sends the cell off to the left like a swipe, then the cells after it slide into place, from
  one row up to the previous one. A quick second tap closes nothing more.
- `sim` **(was broken)** Close a cell and tap Undo while it is still leaving, by button and by swipe: it comes back in its
  own place and its close button works. It used to come back off screen with a dead button.
- `sim` **(was broken)** A cell sliding back stays above its left neighbour the whole way.
- `sim` **(was broken)** A swiped cell's title fades out and doesn't run into the neighbour's title.
- `sim` **(was broken)** Titles scrolled under the bottom bar fade out instead of showing through the glass.
- `sim` A closed folder is one cell with a pile behind it. Tap it to open; the folder name's menu collapses it.
- `sim` A Zen folder tab shows the unload button (moon) only once it has been opened. Unloading keeps the cell.
- `sim` Grid scrolls vertically while a horizontal swipe is not in progress.

## Workspaces and sync

- `sim` Sign in with the Mozilla account. Zen workspaces, essentials, pinned tabs and folders appear.
- `sim` A change made in Zen on the computer (a new folder tab, a new pin) appears after sync.
- `sim` Adding a tab to a Zen folder or removing it from Fir shows up in Zen.
- `sim` Send a tab to a computer: it arrives there.
- `sim` A new-tab search opens in the workspace it was started from, even after the keyboard hides.
- `sim` Sign out: local passwords and history are wiped before sync disconnects.

## Private and locks

- `phone` Private tabs lock with Face ID when the app goes to the background. The lock covers sheets.
- `sim` Nothing from a private tab shows in history, Spotlight, Handoff, snapshots or Live Activities.
- `sim` Closing the last private tab clears its data. The Private section shows its empty page.
- `phone` The app lock, when on, shows over everything on launch and on return.
- `phone` Turning a lock off asks for Face ID.

## Links in and out

- `phone` With Fir as the default browser, a link from another app opens in a new tab in front of any open sheet.
- `sim` A link to another app (for example the App Store) asks first. `tel`, `mailto`, `sms` and `facetime` links
  don't ask.
- `phone` Share on a page offers Add to Home Screen. Private tabs share only the URL.
- `sim` Long-press a link: the preview opens, and tapping it opens a glance.
- `sim` Spotlight text and Shortcuts input are always searched, never opened as an address.
- `sim` Home Screen quick actions: New Tab and New Private Tab.

## Passwords

- `sim` On an https sign-in page, a saved login is offered and fills. Nothing is offered on http.
- `sim` After signing in with new details, Fir offers to save them.
- `phone` The Passwords settings page asks for Face ID.

## Content blocking and site settings

- `sim` With Block Ads & Trackers on, a page with ads loads without them. Turning it off for a site reloads that site
  with ads.
- `sim` HTTPS-Only upgrades an http link and warns when the site has no https.

## Reader, translate, downloads

- `sim` Reader opens on an article and closes back to the same scroll position on the page.
- `sim` Translate a page in another language, then restore the original.
- `sim` A download shows its progress and ends up in Downloads, where it can be opened and shared.
- `sim` Long-press an image, with and without a link, and tap Save to Photos: iOS asks for access once, the image
  lands in Photos, and Fir stays open.
- `phone` On a site's photo upload (tinypng.com), Take Photo opens the camera and iOS asks for access; Fir stays
  open. The simulator never asks, so only a phone shows this.
- `sim` A page asking for the microphone, or starting speech recognition, in the tab in front gets WebKit's prompt. In a
  long-press link preview, a hidden tab or a locked private tab it gets a refusal and no prompt.
- `sim` A site holding the microphone loses it when its tab is switched away, private tabs lock, or Fir goes to the
  background (its track ends).

## Add-ons

- `sim` Install uBlock Origin Lite and Dark Reader from addons.mozilla.org. Both work on a page.
- `sim` **(was broken)** An add-on's settings open in a sheet from Settings > Extensions > the add-on > Extension
  Settings, and from the page menu. A link out of that sheet opens in a tab.
- `sim` Disabling and removing an add-on takes effect without restarting.

## Onboarding and settings

- `sim` Fresh install (`-onboardingDone NO`): every page shows, the choices on New tabs and Your tabs stick, and Skip
  works from any page.
- `sim` What's New shows once after an update (`-whatsNewSeen` one below the current list), and never on a fresh
  install.
- `sim` Every settings page opens and closes, and each picker changes the app straight away. New Tab is under Tabs.

## Accessibility and layout

- `sim` Reduce Motion on: no zoom sheets, no screen recess behind search, and pages switch to the tab overview at once.
- `sim` Light and dark appearance both look right on the page, both tab overviews, and the sheets.
- `sim` Landscape: the bar moves to the top and the tab strip shows.
- `sim` Larger Dynamic Type sizes don't break the bar or the grid titles.
- `sim` **(open)** VoiceOver: after a bar swipe the Tabs button's element spans the whole glass bar, so activating it
  edits the address instead of showing the tabs. The UI tests tap the menu's inner button to step around it.
