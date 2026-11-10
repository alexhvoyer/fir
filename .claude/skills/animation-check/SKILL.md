---
name: animation-check
description: Measure a Fir animation from a screen recording or a fresh simulator capture to find jumps, stalls and glitches frame by frame. Use when an animation looks wrong, or to confirm an animation fix.
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
