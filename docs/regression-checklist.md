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
| `FirShare`, `OpenInFir` | Links in and out, then `fir-security-reviewer` |
| Sync, `ZenSpaces`, `AccountService`, `Bookmarks` | Workspaces and sync |
| `PasswordAutofill`, `PasswordStore` | Passwords |
| `Extensions` | Add-ons |
| Onboarding, What's New, settings | Onboarding and settings |
| Sheets, `KeyCommands`, anything sized by the screen | iPad |
| Layout by screen shape, safe-area insets, the camera column | iPhone Duo and landscape |

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
- `sim` **(was broken)** Dark mode on a light page: the search sheet and the page menu grow out of the bar's glass and
  melt back into it. Closing used to shrink into the bar as a black capsule.
- `sim` With New Tab set to Start Page, tapping the address puts the field in the bar's place with no sheet; it rides
  up on the keyboard. Cancel, or putting the keyboard away, brings the bar back. Landscape still uses the sheet.
- `sim` **(was broken)** A page printing `100svh` and `100lvh` shows less than the screen height, as in Safari. They were
  the whole screen, and a site menu that tall ran under the bar out of reach. `100vh` stays the full height.
- `sim` Settings > Tabs > Tabs Button > New Tab: in portrait the tab count becomes +, a tap opens a new tab, and touch
  and hold shows the menu with Show All Tabs on top. Landscape and the Duo's column keep the tab count beside their +.
- `sim` **(was broken)** Start Page mode: Cancel or Return takes the keyboard down with the field riding on it, then the
  field fades into the bar. Removed at once, both vanished in one frame.
- `sim` **(was broken)** Start Page mode on a page, Cancel: the start page or results stay put while they fade (they
  dropped by the status bar's height and slid back). On the way down the magnifier turns into the menu icon and the
  address into the host where the bar has it; the bar's buttons fade in after. Dark and light.
- `sim` **(was broken)** Same, on a page with back history: the field's left edge slides to the address capsule's,
  and back, reader, share and reload fade in after the landing (they popped in at once). Debug > Slow Animations
  shows the fade.
- `sim` **(was broken)** Cancel, then tap the field as it rides down: the search still closes (the keyboard came back
  with the field's text faded out). Tap the address while "Reader Available" shows, then Cancel: the bar shows the host.
- `sim` Start Page mode on a blank tab: while the field is up, the tab's own start page shows behind it and its tiles
  open in the tab.
- `sim` **(was broken)** Start Page mode on a blank tab: Go on a typed address, or a tile behind the field, takes the
  keyboard down with the field riding on it. A fast page used to cut the field off in one frame.
- `sim` Start Page mode: turning the phone with the field in the bar moves the search into the sheet, never both at once.
- `phone` Start Page mode: the keyboard comes up as fast as in Safari (FrameMeter stall well under the sheet's).
- `sim` **(was broken)** Start Page mode, + on a page (corner button set to New Tab, or the page menu): the new start
  page slides in from the right as a swipe past the last tab does, also from a tab that isn't last. It used to cut.
  Its bar grows from the compact capsule as it lands (it jumped wide at the end), and with text on the clipboard
  the paste button never shows a blank grey square or a bare icon for a frame.
- `sim` **(was broken)** Start Page mode, swipe the bar past the last tab and let go: the new tab's bar grows to full
  width as it lands, as with +. It stayed short, then jumped wide. Called off, no tab is added.
- `sim` Page menu grows out of the menu button or the address. With Reduce Motion it slides up.
- `sim` iPhone Duo outer screen, Full-Width Pages on: en.m.wikipedia.org's search and account buttons sit left of the
  camera pill and open; the header's background and the article stay full width. m.youtube.com's Sign in shows as its
  icon left of the pill; ebay.com's camera and search buttons sit left of it. Same on the open inner screen, where
  the pill is shorter: ebay.com's search field stays full width there. With Full-Width Pages off, or on an iPhone,
  pages are untouched.
- `sim` **(was broken)** Close the page menu and lift to the tab overview at once. The address capsule must not stay
  over the switcher.
- `sim` **(was broken)** With an add-on installed, the bar's buttons don't overlap the address text.
- `sim` The bar collapses on scroll and expands on tap or when a new page starts loading.
- `phone` **(was broken)** Scroll to the very end of a long page and hold: the bar stays as it is and the page stays
  still (the bar flipped between pill and full and the page shook; the simulator never showed it).
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
- `sim` **(was broken)** Tap another workspace in the switcher (or swipe to Private) and press + at once: the new tab
  opens in that workspace, not the one being left. Same in Grid.
- `sim` Essentials and pinned tiles are pale until opened. Tap one: a tab opens and the tile goes full. Switch away,
  tap it again: the same tab comes back, even after it navigated elsewhere, and no new tab is added. Close that tab:
  the tile is pale again. A relaunch keeps the tie. In a private tab's start page an essential opens privately.
- `sim` **(was broken)** Open Duo screen, grid overview with a folder above the selected card: opening a card
  grows only that card; a card from the folder above used to rise and slide across the page. A pale essential's
  new tab grows out of its tile, not out of the corner; in Cards no deck card slides over it. Lifted mid-grow,
  it lands on its new card, not back in the tile.
- `sim` **(was broken)** Duo outer screen, a pale essential for a site with a dark page: the screen never flashes white
  while the page grows. The icon sits mid-page on the theme's background, stays at least half a second from the tap and
  fades into the page, never cut. Offline, the error page shows at once, not after the icon.
- `sim` In a workspace with folders, a folder button sits by Settings (left of it on iPhone, above it in the Duo's
  column). Its menu lists the folders in deck order. Pick one: the deck fans it out and centres its first card, also
  when another folder was open. No button in a workspace without folders, on a device page or in locked Private.
  Switching between a workspace with folders and one without, the button fades and scales in and out, never pops.
- `sim` In a Zen workspace on iPhone, its title sits centred on the top buttons and stops short of them, a long name
  ending in an ellipsis. The essentials start clear below the buttons; cards keep their size. On the Duo, whose
  buttons sit in the column, the title keeps its own place with room above it, not pressed to the top edge.
- `sim` **(was broken)** Switch between a Zen workspace with tabs and one without (its page of pins): the title and
  the essentials stay at the same height, on iPhone and on the Duo. The empty page's title sat about 40 pt lower.
- `sim` iPhone on its side and the open Duo: a Zen workspace's essentials and pinned tabs stand in a column on the
  left, inside the safe area (clear of the island either way round); the cards' tucked stack stays right of it, and
  folder headings keep their icon, count and chevron. A workspace without tabs lists its pinned tabs and folders
  beside the column. iPhone upright and the closed Duo keep the row above the cards. No title on an iPhone on its side.
- `sim` A workspace with both essentials and pinned tabs: a star/pin switch, as tall as the tiles, starts the row
  (stacked at the top of the column on a wide screen) and shows one kind at a time. The choice is kept per
  workspace across relaunches; it scrolls away with the tiles and comes back at the row's start. With only one
  kind there is no switch.
- `sim` **(was broken)** iPhone on its side, switch to a workspace with tabs: once the slide stops the cards stay put.
  They jumped ~30 pt sideways for a few frames (phone: stayed shifted) as the deck went live. Also switch to the
  local tabs page ("N Tabs", no pins column): it kept the jump after the workspaces were fixed.
- `sim` **(was broken)** iPhone on its side, switch workspaces: when the slide stops, the tint fills both sides
  at once and the page doesn't jump. A side stayed untinted for ~150 ms and the page jumped ~36 pt.
- `sim` After a cold launch, a tab not opened yet loads when its card is tapped or it is swiped to, with its bar buttons.
  Restored tabs get their web view only then; closing one that never loaded works and Undo brings it back.
- `sim` **(was broken)** Close a blank tab and tap Undo with Recently Closed empty: the tab comes back. It crashed.
- `sim` **(was broken)** Signed in, with a Zen folder in the workspace: quit Fir, open it, and tap the tabs button at once.
  The page shrinks straight onto its card. The sync's new layout used to send it one card aside first.

## Tab overview: Grid

- `sim` The page grows out of its cell and shrinks back into it, landing exactly on the cell.
- `sim` Pick a folder from the folder button by Settings: it opens and the grid scrolls its name to the top.
- `sim` **(was crossfading)** Open a closed folder in the grid: its cards slide out of the pile into their places and
  the cells after it move to make room; closing slides them back into the pile. No row fades. Try a folder whose
  cards land in a lower row (third pile in the first row on the open Duo): they used to fade in place.
- `sim` **(was broken)** Scroll so the current cell is off centre, then open it: the grid stays still while the page
  grows. It used to jump to centre the cell at the tap.
- `sim` **(was broken)** After closing a page, its cell shows its picture and the selected outline. A LazyVGrid kept
  the picture hidden.
- `phone` **(was broken)** In the grid, scrolled to the end, close the selected tab and the last one in its row: the
  grid rises in one smooth motion. It jumped a third of a row, paused, then slid, as it centred the next selected
  cell and showed its page behind the grid.
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
- `sim` Sign out: local passwords, history and bookmarks are wiped before sync disconnects; Zen keeps its bookmarks.
- `sim` Bookmarks from Zen appear in Settings > Bookmarks under Toolbar, Menu and Other after sync; one added in Fir
  shows in Zen's Mobile Bookmarks.
- `sim` The page menu's bookmark icon fills on tap and empties on a second tap; the card menu offers Add/Remove
  Bookmark. The start page grid shows the newest ten Mobile bookmarks; Settings > Tabs hides it and Frequently Visited.
- `sim` Typing a bookmarked page's name in the search sheet lists it with Bookmarks beside its host; not with a
  keyword chip.
- `phone` Settings > Sync > Device Name: a new name shows in Zen's Send Tab to Device within a minute; an emptied
  field comes back with the current name; offline, the old name returns on reopening Sync.

## Private and locks

- `phone` Private tabs lock with Face ID when the app goes to the background. The lock covers sheets.
- `sim` Nothing from a private tab shows in history, Spotlight, Handoff, snapshots or Live Activities. A private
  tab offers no bookmark action, in the page menu or the card menu.
- `sim` Privacy & Security > Remember History off: new pages don't appear in Settings > History; older entries stay.
  History > Clear offers Last 15 Minutes, 30 Minutes, Last Hour, Today and All History; each removes only that span.
- `sim` Closing the last private tab clears its data. The Private section shows its empty page.
- `sim` **(was broken)** With a regular tab selected, the overview on Private covers the app switcher with Private
  Browsing, as a private tab does. It used to show the private cards.
- `phone` The app lock, when on, shows over everything on launch and on return.
- `phone` Turning a lock off asks for Face ID.
- `sim` Leaving with a private tab or the Private overview shows the cover in the app switcher at once; coming back
  fades it out. Leaving again mid-fade covers at once.

## Links in and out

- `sim` **(was broken)** "Continue with Google" (a page's window opened empty, then sent to Google) shows Google's page
  in a new tab. It used to bring up the search sheet, and sign-in waited until that was closed.
- `sim` **(was broken)** Offline, Try Again keeps the error page up while it retries. It used to flash a blank page on
  every tap. Back online, Try Again loads the page.
- `phone` With Fir as the default browser, a link from another app opens in a new tab in front of any open sheet.
- `sim` A link to another app (for example the App Store) asks first. `tel`, `mailto`, `sms` and `facetime` links
  don't ask.
- `phone` Share on a page offers Add to Home Screen. Private tabs share only the URL.
- `sim` Long-press a link: the preview opens, and tapping it opens a glance.
- `sim` Spotlight text and Shortcuts input are always searched, never opened as an address.
- `sim` Home Screen quick actions: New Tab and New Private Tab.
- `sim` Share sheet in Safari: Fir shows the page title and host. Open in Fir opens the link in a new tab in front.
- `sim` Share sheet signed out: Send to Device asks to sign in to Fir. Signed in: the account's devices are listed.
- `phone` Send to Device from the share sheet: the tab opens on the chosen device and the sheet closes with a tick.
- `phone` A link shared as text from a messenger (Telegram) is found, and Open in Fir opens it.
- `sim` **(security)** Fir's own share sheet on a private tab: Fir's row shows No Link, so the address stays private.
- `sim` **(security)** A page linking to `firbrowser://open?url=...` does nothing: no dialog, no new tab.

## Passwords

- `sim` On an https sign-in page, a saved login is offered and fills. Nothing is offered on http.
- `sim` After signing in with new details, Fir offers to save them.
- `phone` The Passwords settings page asks for Face ID.
- `sim` With Save and Fill Passwords off (Settings > Passwords, shown without unlocking), Fir neither offers a
  saved login nor asks to save one; the keyboard's own Passwords button still works.

## Content blocking and site settings

- `sim` With Block Ads & Trackers on, a page with ads loads without them. Turning it off for a site reloads that site
  with ads.
- `sim` Filter Lists > Add List with an https list address: it appears under Your Lists with its own title and
  rule count. An http address shows an error; a web page or a list over 150,000 rules shows red text and turns off.
  Swipe to delete removes it. The catalog lists keep working throughout.
- `sim` HTTPS-Only upgrades an http link and warns when the site has no https.
- `sim` **(was broken)** Page Zoom on google.com search results: 70% shrinks the whole page evenly and keeps the
  full width (pageZoom left a blank strip, did nothing or spilled off screen); 130% reflows narrower without sideways
  scroll; it stays after reload and relaunch and on turning the phone; other tabs of the site follow; 100% restores.
- `sim` Page Zoom on a page without a viewport tag (desktop layout) and on one that rewrites its tag after load.
- `phone` **(was broken)** Page Zoom 70% on google.com: no tiny or invisible titles (text-size-adjust shrank em-sized
  text again at every level on a real phone, not on the simulator); scrolling has no jitter or jumps back.

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
- `sim` Page menu > Extensions opens a page in the sheet listing every add-on, switched-off ones too. Each opens the
  same page as in Settings, with Open for add-ons that have a settings page. Back and swipe back return; removing
  the last add-on shows No Extensions.
- `sim` With Dark Reader on a light page (info.cern.ch), turning off Allow on info.cern.ch on its page in the sheet
  reloads the page light; another site stays dark, and so does info.cern.ch's state after a relaunch. Settings >
  Extensions > Dark Reader lists the site under Off on These Sites; swiping it to Allow darkens the page again.
- `sim` Dark Reader's popup on a site it's off on shows no address (about:), and its own site button there does nothing.
- `sim` Installing Privacy Badger (`privacy-badger17`) lists "See the addresses of your open tabs" and "See the pages
  you open as they load" under "It will also be able to:"; Cancel installs nothing.

## Onboarding and settings

- `sim` Fresh install (`-onboardingDone NO`): every page shows, the choices on New tabs and Your tabs stick, and Skip
  works from any page. Make it yours sets Tabs Button too; New Tab there shows + in the bar after Start Browsing.
- `sim` **(was broken)** New tabs and Your tabs: a quick tap on either choice animates both sketches both ways (sheet,
  fan, tiles, size, border), and the tick on the choice left goes at once. Search Sheet and Cards used to jump.
- `sim` What's New shows once after an update (`-whatsNewSeen` one below the current list), and never on a fresh
  install.
- `sim` Every settings page opens and closes, and each picker changes the app straight away. New Tab is under Tabs.
- `sim` Search > Search Engine Kagi: typing shows Kagi Suggestions. Add Search Engine: an address without `%s` says
  DuckDuckGo is used meanwhile; `https://html.duckduckgo.com/html/?q=%s` with `fir & tree #1` searches for exactly
  that. Going back with no address drops the new engine. In Russian the footers fit.
- `sim` Quick search, sheet and Start Page bar: `wiki` and a space turn into a Wikipedia chip in place of the magnifier
  and leave the field empty ("Search Wikipedia"); `fir` then shows "fir, Search Wikipedia" and opens Wikipedia.
  Tapping the chip puts `wiki ` back as text and the search goes to the default engine; `b 52 bomber` that way
  searches DuckDuckGo, not Bing. Clear removes the chip. A long engine name is cut short. `yt fir` stays text until
  YouTube's Quick Search is on. An added engine (`oh`, `https://oceanhero.today/web?q=%s`) works as a chip and as the
  default; deleting it while it is the default goes back to DuckDuckGo.
- `phone` Typing `g` and a space quickly, then the query: the `g` never stays in the text next to the chip.

## iPad

- `sim` **(was broken)** On a full-screen iPad, the search sheet and the page menu show all their content. They used
  phone heights in a centered sheet and were cut short.
- `sim` **(was broken)** In landscape, deck cards and grid cells show the page from its top-left corner, not its middle.
- `sim` With a keyboard: Command-T opens new-tab search, Command-L edits the address, Command-W closes the tab,
  Control-Tab moves to the next tab in the workspace. None of them act while Fir or a private tab is locked.
- `sim` Fir opens only one window: two would share one browser, and the lock covers one window.
- `sim` In Split View beside another app, Fir in a narrow column behaves as on an iPhone.

## iPhone Duo and landscape

Record each Duo screen on its own: `xcrun simctl io <udid> recordVideo --display=<display UUID>` (outer: `--display=1`).

- `sim` On both Duo screens, the wide inner one included, the camera column holds + and Tabs on a page, and Settings
  and + in the tab overview; the page stops at the column, as the HIG asks. Back and Forward sit in the
  column above +, the address bar has none, and both of the tab overview's column buttons respond.
- `sim` **(was broken)** On the Duo, shrinking a page into its card and opening it again lands without a sideways
  jump at the end, and nothing is drawn over the camera column.
- `sim` **(was broken)** Lifting a page on the Duo: the next card slides in from the column's edge, slides back out
  when the lift is called off, and no grey strip appears as the tab overview takes over.
- `sim` **(was broken)** Shrinking a page into its card and opening it again shows no black strip below the page, on
  the Duo's inner screen and on an iPhone on its side, in Cards and in Grid.
- `sim` In the tab overview on an iPhone on its side, Settings sits at the left of the bottom bar, and its sheet zooms
  out of that button and back into it.
- `sim` **(was broken)** On the Duo outer screen the camera column takes the page's colour, dark and light, and the
  error page's; a blank tab keeps the start page's grey.
- `sim` **(was broken)** A blank tab's sprig sits a little above the middle on both Duo screens, as on an iPhone, and
  at the same place in its card. It used to sit low on the outer screen and off the inner one.
- `sim` Settings > General > Full-Width Pages shows only on the Duo and starts on. On: pages and the start page run under the
  camera column, and so do the deck's cards; + and Tabs (Settings and + on the deck) float over them, the bottom bars
  stay clear of the column, and shrinking into the deck and back has no jump. Off: page and deck stop at the column.
- `sim` **(was broken)** On the Duo, shrinking a light page (Wikipedia) into the deck shows the deck behind it, not
  the page's colour over the whole screen until it lands.
- `sim` Grid on the Duo's open screen: three wide, page-shaped cells per row, as in Safari; a page opens from its cell
  and shrinks back into it without a jump.

## Accessibility and layout

- `sim` Reduce Motion on: no zoom sheets, no screen recess behind search, and pages switch to the tab overview at once.
- `sim` Light and dark appearance both look right on the page, both tab overviews, and the sheets.
- `sim` Landscape: the bar moves to the top and the tab strip shows.
- `sim` **(was broken)** Landscape with more tabs than fit: the strip's chips, favicons included, end at its capsule.
- `sim` Landscape strip: one tab shows no strip; two to four tabs share its whole width, titles centred; more scroll.
- `sim` **(was broken)** iPhone on its side, Cards: cards slide to the screen's edges, not cut at the side safe areas; the bar and buttons stay inside. Grid stays inside.
- `sim` **(was broken)** iPhone on its side: opening a card and going back to the overview show no white side stripes, and neither a web page nor the start page jumps at either end (start page mode and search sheet mode).
- `sim` Larger Dynamic Type sizes don't break the bar or the grid titles.
- `sim` In Russian and German (launch argument `-AppleLanguages (ru)` or `(de)`), onboarding, the page menu and every
  settings page show no English, and long lines wrap instead of being cut. New interface text goes into the catalogs with
  `scripts/sync-strings.sh` after a simulator build.
- `sim` **(open)** VoiceOver: after a bar swipe the Tabs button's element spans the whole glass bar, so activating it
  edits the address instead of showing the tabs. The UI tests tap the menu's inner button to step around it.
