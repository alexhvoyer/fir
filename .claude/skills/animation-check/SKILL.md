---
name: animation-check
description: Measure a Fir animation from a screen recording or a fresh simulator capture to find jumps, stalls and glitches frame by frame, and check that a drag can be called off. Use when an animation looks wrong, to confirm an animation fix, or after changing any gesture or sheet.
---

# Check an animation

Look at frames; do not reason about the animation from code alone. Compare with a case that works, such as
an old tab against a new one, or the swipe in the other direction.

1. Get a video: one the user recorded, or capture one. Find the booted simulator with
   `xcrun simctl list devices booted`. Run this in the background, wait 3 seconds, perform the gesture, then
   stop it with `pkill -INT -f recordVideo` (the recorder then reports exit code 1, which is normal):

   `xcrun simctl io <udid> recordVideo --codec h264 --force <video>`

   Debug > Slow Animations in Simulator stretches a transition across many frames.

2. Tile the frames that changed, then read the image. Crop to the part that matters. The bottom bar of a
   1206x2622 recording is `crop=1206:230:0:2392`.

   `ffmpeg -y -i <video> -vf "mpdecimate=hi=300:lo=150:frac=0.02,scale=200:-1,tile=8x5" -fps_mode vfr -frames:v 1 <out.png>`

3. Measure with `${CLAUDE_SKILL_DIR}/scripts/frames.py`. Run it with `python3 -I`; it needs numpy and ffmpeg.
   - `jumps <video>` lists the largest changes between frames. A single spike well above its neighbours is a jump.
   - `track <video>` prints the horizontal shift of each frame, for swipes. It rounds to whole points per frame, so
     it misses slow creep.
   - `tile <video> <first> <last> <out.png>` puts a frame range side by side at a readable size.

4. Reproduce the fault before changing code, then repeat the same capture after the fix. Report the numbers from both,
   and say what could only be judged on a phone.

## Gestures that follow the finger

`jumps` finds snaps, not wrong behaviour: a page springing back too early is smooth and shows no spike, and a drag
that can't be called off only shows if it is called off. For every interactive gesture you touched (tab swipe, lift to
the deck, deck cards, sheets), capture all three:

- **Finish:** drag slowly past the point of no return, hold, release.
- **Call off:** drag part of the way, hold, come back to the start, hold, release.
- **Flick:** a fast release, and a flick back against the drag.

Read the tiled frames and check, frame by frame:

- Nothing irreversible happens while the finger is down: no navigation, dismissal, or state written.
- Everything tied to the gesture moves with the finger. Something moving before the dragged object has moved is a fault.
- After calling off, the screen is exactly as it started, keyboard and focus included.
- A second gesture during the first one's landing still counts.

Use `touch_path` for these: `dt_ms` holds a position, which `swipe` cannot. Start the recording and run the gesture
in one message, since a turn between them can put the gesture minutes into the video. If a window is too short to hit,
temporarily stretch that animation behind a launch argument containing `dbg`, and compare against the old logic the
same way. A control run only counts if the gesture reached the code it is meant to test.

Injected touches can misreport: a sheet opened with the zoom transition closed at once on the simulator, yet followed a
real finger on the phone. Confirm such a fault on a phone before changing code.
