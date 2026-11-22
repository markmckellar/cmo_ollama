#!/usr/bin/env python3
"""Was it a delivery? The porch camera's check of a visit to the front door (one or more back-to-back clips).

Usage: delivery.py [-m model] <movie> [<movie> ...]
  Checks each movie and then the movies together as one visit (give them in time order). Prints one JSON line
  per movie and a last line with the visit's answer, e.g. {"delivery": true, "package": true, "round_trip": true}.

A delivery is a visit where
  1. some clip shows a package: delivery_question (ollama_common.bash) makes the model list what people hold
     and say whether anyone wears a delivery uniform. It is a package when an item names a box, package,
     envelope, letters, mail, paper or a bag (not a handbag or backpack), or a uniform is seen. The question is
     asked twice per clip: about the 8 frames where things change most (call_ollama_movie.bash -n 8 -s motion
     -c), and about 8 frames cropped to the person, 6 from the first half of their time in the clip (when a
     courier still has the package) and 2 from the second half. A person far away on the path is too small to
     see what they carry in the whole 640x360 frame.
  2. the person made a round trip: person_box_question finds the box around each person in 16 frames of every
     clip, one frame at a time. Their height (0-1000 of the picture) over the whole visit must start small
     (< 400: on the path or the sidewalk), reach the door (>= 450) and end small again (< 450: gone back down
     the path). The porch camera pans to follow people, so the box's size says how near the door they are and
     its position doesn't. Someone coming home ends at the door and goes in; someone leaving starts there.
Only the clips with a person get the questions (the caller decides which; see check_clip).

Tested on cmo_test_data's porch clips (2026-11-22, qwen3-vl:8b): 48 of 50 delivery visits with 6 false alarms in
100 others, and 10 of 12 with 2 in 33 on clips not used for tuning. Residents carrying groceries in and out
again look the same as a courier. About 30 s of GPU per clip: 16 finder calls and 2 questions.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import call_ollama  # noqa: E402

SAMPLES = 16                    # frames per clip the person finder looks at
START_BELOW, END_BELOW, DOOR_AT = 400, 450, 450     # person heights (0-1000) for a round trip
TILE_W, TILE_H = 336, 252       # each frame of the cropped grid (4:3); 3 columns, about 1024 px wide
PACKAGE = re.compile(r"box|package|parcel|envelope|letter|mail|paper bag|plastic bag|shopping bag|grocery"
                     r"|delivery bag|insulated bag|bag of|food bag|^bag$|mailer|bubble|^paper|papers|flyer")


def has_package(answer):
    """True when an answer to delivery_question names a package-like item or a delivery uniform."""
    if not answer:
        return False
    items = answer.get("carrying") or []
    if isinstance(items, str):
        items = [items]
    return answer.get("uniform") is True or any(PACKAGE.search(str(x).lower()) for x in items)


def _duration(movie):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(movie)],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return float(r.stdout.decode().strip() or 0)


def _grab(movie, t, out, vf=None):
    """One frame at t seconds into out; steps back a little at the very end of a clip, where there may be none."""
    for back in (0, 0.3, 0.6, 1.0, 1.5, 2.0):
        if os.path.exists(out):
            os.remove(out)
        cmd = ["ffmpeg", "-v", "error", "-y", "-ss", "{:.2f}".format(max(0.0, t - back)), "-i", str(movie),
               "-frames:v", "1"] + (["-vf", vf] if vf else []) + [str(out)]
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if os.path.exists(out) and os.path.getsize(out) > 0:
            return True
    return False


def _union(boxes):
    good = [b for b in boxes if isinstance(b, list) and len(b) == 4 and all(isinstance(v, (int, float)) for v in b)]
    if not good:
        return None
    return [min(b[0] for b in good), min(b[1] for b in good), max(b[2] for b in good), max(b[3] for b in good)]


def find_people(movie, model, stats=None, work=None):
    """[(seconds, [x1, y1, x2, y2])]: the box around everyone (0-1000) in each of SAMPLES evenly spaced frames
    that has a person. Returns None when Ollama doesn't answer at all."""
    question = call_ollama.setting("person_box_question")
    dur = _duration(movie)
    if dur <= 0:
        return None
    step = dur / SAMPLES
    found, answered = [], 0
    frame = os.path.join(work, "find.png")
    for i in range(SAMPLES):
        t = step * (i + 0.5)
        if not _grab(movie, t, frame):
            continue
        a = call_ollama._run([HERE / "call_ollama.bash", model, question, frame], 60, stats)
        if a is None:
            continue
        answered += 1
        box = _union(a.get("people") or [])
        if box:
            found.append((round(t, 2), box))
    return found if answered else None


def _box_at(t, found):
    """The person's box at t, between the finder's frames."""
    before = [x for x in found if x[0] <= t]
    after = [x for x in found if x[0] >= t]
    if not before:
        return after[0][1]
    if not after:
        return before[-1][1]
    (t0, b0), (t1, b1) = before[-1], after[0]
    k = 0 if t1 == t0 else (t - t0) / (t1 - t0)
    return [b0[i] + (b1[i] - b0[i]) * k for i in range(4)]


def _crop(box):
    """ffmpeg filter: the box (0-1000), padded and grown to the tile's shape, at least 40% of the frame high."""
    x1, y1, x2, y2 = (v / 1000 for v in box)
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    h = max((y2 - y1) * 1.4, 0.4)
    w = max((x2 - x1) * 1.6, h * (4 / 3) * (9 / 16))
    h = max(h, w * (16 / 9) * (3 / 4))
    w, h = min(w, 1.0), min(h, 1.0)
    x, y = min(max(cx - w / 2, 0), 1 - w), min(max(cy - h / 2, 0), 1 - h)
    return ("crop=iw*{:.4f}:ih*{:.4f}:iw*{:.4f}:ih*{:.4f},scale={}:{}:force_original_aspect_ratio=decrease,"
            "pad={}:{}:(ow-iw)/2:(oh-ih)/2:color=black").format(w, h, x, y, TILE_W, TILE_H, TILE_W, TILE_H)


def _spread(lo, hi, n):
    return [(lo + hi) / 2] if n == 1 else [lo + (hi - lo) * i / (n - 1) for i in range(n)]


def arrival_answer(movie, found, model, stats=None, work=None):
    """delivery_question about 8 frames cropped to the person: 6 from the first half of their time in the clip,
    2 from the second. None without a person or an answer."""
    if not found:
        return None
    dur = _duration(movie)
    step = dur / SAMPLES
    p0, p1 = max(0.0, found[0][0] - step / 2), min(dur - 0.1, found[-1][0] + step / 2)
    mid = (p0 + p1) / 2
    times = _spread(p0, mid, 6) + _spread(mid, p1, 3)[1:]
    paths = []
    for i, t in enumerate(times):
        p = os.path.join(work, "c{:02d}.png".format(i))
        if not _grab(movie, t, p, _crop(_box_at(t, found))):
            return None
        paths.append(p)
    lst, grid = os.path.join(work, "list.txt"), os.path.join(work, "crop_grid.png")
    with open(lst, "w") as f:
        f.writelines("file '{}'\n".format(p) for p in paths)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-vf",
                    "tile=3x3:padding=4:margin=4:color=white", "-frames:v", "1", grid],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(grid):
        return None
    prefix = ("This image is a grid of 8 frames (3 rows by 3 columns, separated by white lines) taken in time "
              "order from one security camera video clip. Consider every frame: something counts as present if "
              "it appears in any frame. Each frame is zoomed in on the person in it.")
    return call_ollama._run([HERE / "call_ollama.bash", model, prefix + " " + call_ollama.setting("delivery_question"),
                             grid], 120, stats)


def check_clip(movie, model=call_ollama.DEFAULT_MODEL, stats=None):
    """One clip with a person: {"found": [(t, box)], "heights": [...], "motion_answer": {...},
    "crop_answer": {...}, "package": bool}, or None when Ollama didn't answer."""
    work = tempfile.mkdtemp(prefix="cmo_delivery_")
    try:
        found = find_people(movie, model, stats, work)
        if found is None:
            return None
        motion = call_ollama._run([HERE / "call_ollama_movie.bash", "-n", "8", "-s", "motion", "-c", model,
                                   call_ollama.setting("delivery_question"), movie], 180, stats)
        crop = arrival_answer(movie, found, model, stats, work)
        return {"found": found, "heights": [b[3] - b[1] for _, b in found], "motion_answer": motion,
                "crop_answer": crop, "package": has_package(motion) or has_package(crop)}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def round_trip(heights):
    """The visit's person heights (0-1000, in time order) start on the path, reach the door and end on the path."""
    return bool(heights) and heights[0] < START_BELOW and heights[-1] < END_BELOW and max(heights) >= DOOR_AT


def decide(clips):
    """The visit's answer from its clips' check_clip results in time order (None for a clip without a person)."""
    clips = [c for c in clips if c]
    heights = [h for c in clips for h in c["heights"]]
    package = any(c["package"] for c in clips)
    trip = round_trip(heights)
    return {"delivery": package and trip, "package": package, "round_trip": trip,
            "heights": [heights[0], max(heights), heights[-1]] if heights else []}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-m", "--model", default=call_ollama.DEFAULT_MODEL)
    ap.add_argument("movies", nargs="+")
    args = ap.parse_args()
    results = []
    for movie in args.movies:
        r = check_clip(movie, args.model)
        results.append(r)
        print(json.dumps({"movie": movie, **(r or {"error": "no answer"})}), flush=True)
    print(json.dumps(decide(results)))


if __name__ == "__main__":
    main()
