"""Frame measurements for screen recordings: jumps, track and tile. See SKILL.md."""
import subprocess
import sys

import numpy as np


def timestamps(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time",
                          "-of", "csv=p=0", path], capture_output=True, text=True, check=True).stdout
    return [float(line.strip(",")) for line in out.split()]


def frames(path, width=402, height=874):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={width}:{height},format=gray",
                          "-fps_mode", "passthrough", "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    count = len(raw) // (width * height)
    return np.frombuffer(raw, np.uint8)[:count * width * height].reshape(count, height, width).astype(np.float32)


def jumps(path):
    video, times = frames(path), timestamps(path)
    change = np.abs(video[1:] - video[:-1]).mean(axis=(1, 2))
    print(f"frames {len(video)}, median change {np.median(change):.2f}")
    for index in np.argsort(-change)[:8]:
        print(f"frame {index + 1:5d}  t={times[index + 1]:7.3f}s  change={change[index]:.2f}")


def track(path):
    video, times = frames(path), timestamps(path)
    band = video[:, 100:760, :]
    width, position = band.shape[2], 0
    for index in range(1, len(band)):
        before, after = band[index - 1], band[index]
        if np.abs(before - after).mean() < 0.02:
            continue
        errors = {}
        for shift in range(-120, 121):
            left, right = max(0, shift), width + min(0, shift)
            errors[shift] = np.abs(before[:, left - shift:right - shift] - after[:, left:right]).mean()
        best = min(errors, key=errors.get)
        position += best
        print(f"t={times[index]:7.3f}s  step={best:5d}  x={position:6d}")


def tile(path, first, last, out):
    count = int(last) - int(first) + 1
    columns = min(count, 8)
    rows = (count + columns - 1) // columns
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-vf",
                    f"select='between(n,{first},{last})',scale=240:-1,tile={columns}x{rows}",
                    "-fps_mode", "vfr", "-frames:v", "1", out], check=True)
    print(out)


if __name__ == "__main__":
    commands = {"jumps": jumps, "track": track, "tile": tile}
    if len(sys.argv) < 3 or sys.argv[1] not in commands:
        sys.exit("usage: frames.py jumps|track <video>  or  frames.py tile <video> <first> <last> <out.png>")
    commands[sys.argv[1]](*sys.argv[2:])
