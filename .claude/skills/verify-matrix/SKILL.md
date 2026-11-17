---
name: verify-matrix
description: Before changing anything visible in Fir, write out every place the change must be checked (screens, appearance, language, modes, states, transitions, taps); after it, fill each cell with evidence and report the unchecked ones. Use at the start of any UI, layout, animation, gesture or copy change, and before reporting such a change done.
---

# Verify matrix

The request names one case; the user checks them all. List the cells before writing code, so the plan for checking
is fixed before the code invites a narrower one. A cell is done when there is evidence for it, not when it should work.

## 1. Find what the change touches

- Name the views, transitions and settings the change reaches, through the call sites, not only the edited lines.
- Run the map in `docs/regression-checklist.md` ("Which sections to run") and take its sections' cases in.
- For a reported fault, search for the same pattern elsewhere first (the same modifier, the same layout assumption,
  the same missing case). Every hit is fixed in this change or listed as left, with a reason.

## 2. Build the matrix

Take every dimension the change can reach. Each value of each dimension gets at least one cell; add the
combinations the change couples (a geometry change times every transition, a colour change times both appearances).

| Dimension | Values |
| --- | --- |
| Screen | iPhone upright; iPhone on its side; Duo outer screen; Duo inner screen; iPad full width |
| Appearance | light; dark; a dark page in light mode and a light page in dark mode |
| Language | English; the longest one for the text (usually Russian or German) |
| Settings | Tab Overview Cards / Grid; New Tab Search Sheet / Start Page; bar collapsed; Reduce Motion |
| State | blank tab; loaded page; page with back history; error page; private tab, locked and open; Zen folder tab |
| Motion | shrink to the deck and grow back; lift (finish, call off, flick); tab swipe; sheet open and close; keyboard ride |
| Input | a tap on every control touched, not a screenshot of it; long press; hardware keyboard on iPad |

Write the matrix into the conversation before coding: one row per cell, with how it will be checked (screenshot,
recording plus `/animation-check`, tap, UI test) and where (`sim`, or `phone` when only a device shows it: Face ID,
120 Hz feel, the default-browser entitlement).

## 3. Check each cell

- Dark mode: `xcrun simctl ui <udid> appearance dark`. Language: launch with `-AppleLanguages '(ru)'`.
- Duo: the simulator boots on the outer screen, `--display=1` for `simctl io`. The inner screen needs the user to
  unfold it in Simulator.app; record it with `--display=<UUID from simctl io <udid> enumerate>`. Ask for that early.
- On its side: the simulator control's `rotate`, then a fresh screenshot before any tap.
- Taps go through the simulator control or a UI test, and the result is read back. A button seen is not a button
  that responds.
- Flaky behaviour (the keyboard ride, timing races): repeat, and compare with a control build. One run proves nothing.
- UI tests never run on the signed-in simulator.

## 4. Report

The matrix again, each cell marked:
- **checked**: what showed it (screenshot path, recording plus frame numbers, test name);
- **not checked**: why, and who can check it (for example "phone: needs Face ID").

"Done" is said only when no cell is silently missing. A design choice the request left open is listed as a
question, with the HIG's answer built and the other described.
