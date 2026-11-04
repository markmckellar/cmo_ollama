#!/usr/bin/env python3
"""Pick the frames of a movie clip where something is moving.

Usage: pick_motion_frames.py [--select motion|average|mixed|window|box] [--ranges 22-45,67-90f] <movie-file> <frame_count> [sample_fps]

Prints frame_count timestamps in seconds, one per line, in time order.

--ranges (default: the whole clip) only considers frames inside the given ranges,
comma separated. A bare number is seconds, so 22-45 is 22s to 45s; a number with
an f is a movie frame number, so 900f-1080f is converted with the clip's frame
rate. Everything else (background, scores, picks) uses only the frames inside
the ranges.

--select (default motion):
  motion   the frames with movement, as described below
  average  split the clip into frame_count equal parts and take the frame closest
           to each part's average, like ffmpeg's thumbnail filter. Shows what the
           clip mostly looks like, such as a cat sitting still for a minute.
  mixed    half of each: the larger half (rounded up) from motion, the rest from
           average, never two picks within half a second of each other
  window   frame_count movement picks then frame_count average picks, all inside
           the event window: from the first to the last frame that differs from
           the background, padded by a second either side. Empty time before and
           after the event isn't sampled. A clip with no event uses the whole clip.
  box      instead of timestamps, print the part of the picture where something
           moved, as "x y width height" fractions (0-1) of the frame, for
           cropping the frames to it (frame_count is ignored). The box has the
           frame's shape, is at least BOX_MIN of it and is padded, so the moving
           thing and some of what's around it show. Prints nothing (and exits 0)
           when nothing moved or the box would be most of the frame anyway.

ffmpeg's thumbnail filter picks the frame closest to the average of each
segment, which in a mostly empty clip is an empty frame, so a cat that comes
through the flap in a second gets missed. Instead this:

  1. reads the clip at sample_fps (default 4) as tiny greyscale frames
  2. builds a background from the per-pixel median, which drops anything that
     is only there for part of the clip
  3. scores each frame by how far it is from the background, after taking out
     the overall brightness change (the camera's exposure shifts when the door
     opens or a light comes on)
  4. takes the frames that score well above the quiet frames and spreads the
     picks evenly over them; if nothing moves, spreads them over the whole clip

Only the standard library is used, so it runs on the Pi without numpy.
"""
import re
import statistics
import subprocess
import sys
from fractions import Fraction

WIDTH, HEIGHT = 64, 48
# a frame is "active" if its score is this far from the quiet level to the loudest frame
ACTIVE_FRACTION = 0.25
# below this much difference (grey levels out of 255) nothing is moving
MIN_MOTION = 2.0
# box: a pixel this far from the background (grey levels) in at least BOX_FRAMES frames has moved
BOX_PIXEL_DIFF = 20
BOX_FRAMES = 2
# box: moved pixels at most BOX_JOIN apart are one blob; blobs with less than BOX_KEEP of the
# busiest blob's changes are left out
BOX_JOIN = 2
BOX_KEEP = 0.25
# box: the smallest box, as a fraction of the frame's height and width, how much it is padded
# around the moving pixels, and the largest box worth cropping to
BOX_MIN = 0.3
BOX_PAD = 1.3
BOX_MAX = 0.85


def read_frames(movie, fps):
    raw = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", movie,
         "-vf", f"fps={fps},scale={WIDTH}:{HEIGHT},format=gray",
         "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE, check=True).stdout
    size = WIDTH * HEIGHT
    return [raw[i:i + size] for i in range(0, len(raw) - size + 1, size)]


def spread(items, count):
    """count items evenly spaced through items, keeping order."""
    if len(items) <= count:
        return list(items)
    step = len(items) / count
    return [items[int(step * i + step / 2)] for i in range(count)]


def pick(frames, count):
    background = bytes(statistics.median_low(pixel) for pixel in zip(*frames))
    background_mean = sum(background) / len(background)
    scores = []
    for frame in frames:
        shift = sum(frame) / len(frame) - background_mean
        scores.append(sum(abs(p - b - shift) for p, b in zip(frame, background)) / len(frame))

    quiet = statistics.median(scores)
    loudest = max(scores)
    if loudest - quiet < MIN_MOTION:
        return spread(range(len(frames)), count)

    threshold = quiet + ACTIVE_FRACTION * (loudest - quiet)
    active = [i for i, s in enumerate(scores) if s >= threshold]
    picks = spread(active, count)
    if len(picks) < count:
        # short burst of motion: fill up with the next most different frames
        rest = sorted((i for i in range(len(frames)) if i not in picks), key=lambda i: -scores[i])
        picks += rest[:count - len(picks)]
    return sorted(picks)


def average_ranked(frames, count):
    """For each of count equal parts of the clip, its frame indexes ordered from
    closest to furthest from the part's average frame."""
    ranked = []
    for part in range(count):
        start = part * len(frames) // count
        end = max((part + 1) * len(frames) // count, start + 1)
        segment = range(start, min(end, len(frames)))
        mean = [sum(pixel) / len(segment) for pixel in zip(*(frames[i] for i in segment))]
        ranked.append(sorted(segment, key=lambda i: sum(abs(p - m) for p, m in zip(frames[i], mean))))
    return ranked


def motion_scores(frames):
    background = bytes(statistics.median_low(pixel) for pixel in zip(*frames))
    background_mean = sum(background) / len(background)
    scores = []
    for frame in frames:
        shift = sum(frame) / len(frame) - background_mean
        scores.append(sum(abs(p - b - shift) for p, b in zip(frame, background)) / len(frame))
    return scores


def event_window(frames, fps):
    """(first, last) frame index of the event, padded by a second, and the scores."""
    scores = motion_scores(frames)
    quiet = statistics.median(scores)
    loudest = max(scores)
    if loudest - quiet < MIN_MOTION:
        return 0, len(frames) - 1, scores, None
    threshold = quiet + ACTIVE_FRACTION * (loudest - quiet)
    # flicker from lights and the camera shows up as short bursts. Runs of
    # activity at least three-quarters of a second long are kept, runs less than
    # two seconds apart are joined, and the event is the joined run with the most
    # activity overall, so a light change early in the clip doesn't become the start
    min_run = max(1, int(fps * 0.75))
    max_gap = int(fps * 2)
    runs, start = [], None
    for i, s in enumerate(scores + [quiet]):
        if s >= threshold and start is None:
            start = i
        elif s < threshold and start is not None:
            if i - start >= min_run:
                runs.append([start, i - 1])
            start = None
    if not runs:
        return 0, len(frames) - 1, scores, None
    clusters = [runs[0][:]]
    for a, b in runs[1:]:
        if a - clusters[-1][1] <= max_gap:
            clusters[-1][1] = b
        else:
            clusters.append([a, b])
    lo, hi = max(clusters, key=lambda c: sum(scores[c[0]:c[1] + 1]) - quiet * (c[1] - c[0] + 1))
    pad = int(fps)
    return max(0, lo - pad), min(len(frames) - 1, hi + pad), scores, threshold


def pick_window(frames, count, fps):
    lo, hi, scores, threshold = event_window(frames, fps)
    inside = range(lo, hi + 1)
    # movement picks: the active frames inside the window, spread evenly
    if threshold is None:
        motion = spread(inside, count)
    else:
        active = [i for i in inside if scores[i] >= threshold]
        motion = spread(active, count)
        if len(motion) < count:
            rest = sorted((i for i in inside if i not in motion), key=lambda i: -scores[i])
            motion += rest[:count - len(motion)]
    # average picks: the frame closest to the average of each part of the window
    window_frames = frames[lo:hi + 1]
    average = [lo + ranked[0] for ranked in average_ranked(window_frames, count)]
    return sorted(motion) + average


def pick_mixed(frames, count, fps):
    picks = pick(frames, (count + 1) // 2)
    too_close = max(1, int(fps / 2))  # samples in half a second
    for candidates in average_ranked(frames, count - len(picks)):
        for i in candidates:
            if all(abs(i - p) >= too_close for p in picks):
                picks.append(i)
                break
        else:
            picks.append(candidates[0])
    return sorted(picks)


def blobs(pixels):
    """Group pixel indexes into blobs of pixels at most BOX_JOIN apart. Returns a list of sets."""
    left, groups = set(pixels), []
    while left:
        todo = [left.pop()]
        group = set(todo)
        while todo:
            i = todo.pop()
            x, y = i % WIDTH, i // WIDTH
            for ny in range(max(0, y - BOX_JOIN), min(HEIGHT, y + BOX_JOIN + 1)):
                for nx in range(max(0, x - BOX_JOIN), min(WIDTH, x + BOX_JOIN + 1)):
                    j = ny * WIDTH + nx
                    if j in left:
                        left.remove(j)
                        group.add(j)
                        todo.append(j)
        groups.append(group)
    return groups


def motion_box(frames):
    """(x, y, width, height) fractions of the frame to crop to, or None: see --select box."""
    background = bytes(statistics.median_low(pixel) for pixel in zip(*frames))
    background_mean = sum(background) / len(background)
    changed = [0] * len(background)
    for frame in frames:
        shift = sum(frame) / len(frame) - background_mean
        for i, (p, b) in enumerate(zip(frame, background)):
            if abs(p - b - shift) > BOX_PIXEL_DIFF:
                changed[i] += 1
    moved = [i for i, n in enumerate(changed) if n >= BOX_FRAMES]
    if len(moved) < 3:
        return None
    # something that moves for a long time (the cat on the porch) outweighs something that only
    # passes through (a car in the street), so keep only the blobs that changed in nearly as many
    # pixel-frames as the busiest one
    groups = [(sum(changed[i] for i in g), g) for g in blobs(moved)]
    heaviest = max(w for w, _ in groups)
    kept = [i for w, g in groups if w >= BOX_KEEP * heaviest for i in g]
    xs = [i % WIDTH for i in kept]
    ys = [i // WIDTH for i in kept]
    x0, x1 = min(xs) / WIDTH, (max(xs) + 1) / WIDTH
    y0, y1 = min(ys) / HEIGHT, (max(ys) + 1) / HEIGHT
    # the frame's shape, so the same fraction across and down
    size = max(x1 - x0, y1 - y0, BOX_MIN) * BOX_PAD
    if size >= BOX_MAX:
        return None
    # centred on the movement, moved back inside the frame where it would stick out
    x = min(max((x0 + x1 - size) / 2, 0.0), 1.0 - size)
    y = min(max((y0 + y1 - size) / 2, 0.0), 1.0 - size)
    return x, y, size, size


def native_fps(movie):
    rate = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=r_frame_rate", "-of", "csv=p=0", movie],
        stdout=subprocess.PIPE, check=True).stdout.decode().strip()
    return float(Fraction(rate))


def parse_ranges(text, movie):
    """'22-45,900f-1080f' -> [(22.0, 45.0), (37.5, 45.0)] as (start, end) seconds."""
    spans = []
    for part in text.split(","):
        m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)(f?)\s*-\s*(\d+(?:\.\d+)?)(f?)\s*", part)
        if not m:
            sys.exit(f"bad range {part.strip()!r}, use e.g. 22-45 (seconds) or 900f-1080f (frames)")
        fps = native_fps(movie) if "f" in (m.group(2), m.group(4)) else 1.0
        start, end = float(m.group(1)), float(m.group(3))
        if m.group(2):
            start /= fps
        if m.group(4):
            end /= fps
        if end < start:
            sys.exit(f"range {part.strip()!r} ends before it starts")
        spans.append((start, end))
    return spans


def select_frames(frames, select, count, fps):
    if select == "motion":
        return pick(frames, count)
    if select == "average":
        return sorted(ranked[0] for ranked in average_ranked(frames, count))
    if select == "window":
        return pick_window(frames, count, fps)
    return pick_mixed(frames, count, fps)


def main():
    args = sys.argv[1:]
    options = {"--select": "motion", "--ranges": None}
    while len(args) >= 2 and args[0] in options:
        options[args[0]] = args[1]
        args = args[2:]
    select = options["--select"]
    if len(args) not in (2, 3) or select not in ("motion", "average", "mixed", "window", "box"):
        sys.exit(__doc__)
    movie, count = args[0], int(args[1])
    fps = float(args[2]) if len(args) == 3 else 4.0
    frames = read_frames(movie, fps)
    if not frames:
        sys.exit(f"no frames read from {movie}")
    keep = list(range(len(frames)))
    if options["--ranges"]:
        spans = parse_ranges(options["--ranges"], movie)
        keep = [i for i in keep if any(lo <= i / fps <= hi for lo, hi in spans)]
        if not keep:
            sys.exit(f"no frames of {movie} inside {options['--ranges']}")
    if select == "box":
        box = motion_box([frames[i] for i in keep])
        if box:
            print(" ".join(f"{v:.3f}" for v in box))
        return
    picks =select_frames([frames[i] for i in keep], select, count, fps)
    for j in picks:
        print(f"{keep[j] / fps:.2f}")


if __name__ == "__main__":
    main()
