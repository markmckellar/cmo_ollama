"""Run the cmo_ollama scripts from Python, for the cameras (cmo_watch.py in the cmo_client repo, for the
porch and the pet door), so every camera classifies the same way as the scripts that are tested here.

  import sys; sys.path.insert(0, os.path.expanduser("~/dev/cmo_ollama"))
  import call_ollama
  calls = []
  labels, secs = call_ollama.classify_movie("me_movie.mp4", "qwen3-vl:8b", stats=calls)
  # {"legs": false, "person": true, "cat": false, "dog": false, "raccoon": false, "animal": false}
  call_ollama.summarize(calls)
  # {"calls": 1, "num_ctx": 2048, "prompt_tokens": 1469, "output_tokens": 33, "ollama_seconds": 1.7, ...}

The Ollama server, the question and how frames are picked all come from these scripts and
ollama_common.bash (see README.md). Runs on Python 3.7 and newer.
"""
import json
import logging
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

log = logging.getLogger("call_ollama")

HERE = Path(__file__).resolve().parent
LABELS = ["legs", "person", "cat", "dog", "raccoon", "animal"]
DEFAULT_MODEL = "qwen3-vl:8b"
DEFAULT_QUESTION = "person_animal_question"
KEEP_ALIVE = "30m"
# Where the cmo cameras and these scripts keep their logs: porch_watch.log, pet_watch.log and
# call_ollama.log (the scripts' own messages for the cameras' calls).
LOG_DIR = Path(os.environ.get("CMO_LOG_DIR") or Path.home() / "logs")
SCRIPT_LOG = LOG_DIR / "call_ollama.log"      # keep the model loaded between events (see ollama_keep_alive in call_ollama.bash)


def setup_log_file(path, verbose=False):
    """Log a camera's messages to path (in LOG_DIR), rolling over at 5 MB and keeping 3 old files, and to
    the terminal when there is one. The same for every camera."""
    import logging.handlers
    import sys
    root = logging.getLogger()
    root.setLevel(logging.DEBUG if verbose else logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S")
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    fh = logging.handlers.RotatingFileHandler(str(path), maxBytes=5 * 2 ** 20, backupCount=3)
    fh.setFormatter(fmt)
    root.addHandler(fh)
    if sys.stderr.isatty():
        sh = logging.StreamHandler()
        sh.setFormatter(fmt)
        root.addHandler(sh)
    logging.getLogger("urllib3").setLevel(logging.WARNING)


def _run(cmd, timeout, stats=None):
    """Run a script and return its answer as a dict, or None if it failed or answered {}.
    stats: a list that gets one dict per Ollama call the script made (call_ollama.bash's stats line:
    model, image_count, num_ctx, prompt_tokens, output_tokens, total_seconds, load_seconds)."""
    env = dict(os.environ)
    env.setdefault("ollama_keep_alive", KEEP_ALIVE)
    env.setdefault("quiet", "false")                     # log every call to SCRIPT_LOG
    env.setdefault("ollama_log_file", str(SCRIPT_LOG))
    stats_file = None
    if stats is not None:
        fd, stats_file = tempfile.mkstemp(prefix="ollama_stats_", suffix=".jsonl")
        os.close(fd)
        env["ollama_stats_file"] = stats_file
    try:
        r = subprocess.run([str(c) for c in cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           stdin=subprocess.DEVNULL, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        log.warning("%s: no answer after %ss", Path(cmd[0]).name, timeout)
        return None
    finally:
        if stats_file:
            stats.extend(_read_stats(stats_file))
            os.unlink(stats_file)
    lines = r.stdout.decode(errors="replace").strip().splitlines()
    try:
        answer = json.loads(lines[-1]) if lines else {}
    except ValueError:
        answer = {}
    if not answer:
        err = r.stderr.decode(errors="replace").strip()[-300:]
        log.warning("%s failed (exit %s)%s; see %s", Path(cmd[0]).name, r.returncode, ": " + err if err else "",
                    env["ollama_log_file"])
        return None
    return answer


def _read_stats(path):
    calls = []
    try:
        with open(path) as f:
            for line in f:
                try:
                    calls.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return calls


def summarize(calls):
    """Totals of a list of stats dicts (from the stats= argument): {"calls", "num_ctx" (the largest),
    "prompt_tokens", "output_tokens", "ollama_seconds", "load_seconds"}, or {} for no calls."""
    if not calls:
        return {}

    def total(key):
        return sum(c.get(key) or 0 for c in calls)
    return {"calls": len(calls), "num_ctx": max(c.get("num_ctx") or 0 for c in calls),
            "prompt_tokens": total("prompt_tokens"), "output_tokens": total("output_tokens"),
            "ollama_seconds": round(total("total_seconds"), 1), "load_seconds": round(total("load_seconds"), 1)}


def describe(calls):
    """The stats of a list of calls for a log line:
    'ollama: 2 calls, context 2048, prompt 1469+1469 tokens, output 33+21 tokens, 3.4s (load 0.0s)'."""
    if not calls:
        return "ollama: no stats"

    def each(key):
        return "+".join(str(c.get(key)) for c in calls)
    t = summarize(calls)
    return "ollama: {} call{}, context {}, prompt {} tokens, output {} tokens, {:.1f}s (load {:.1f}s)".format(
        t["calls"], "" if t["calls"] == 1 else "s", t["num_ctx"], each("prompt_tokens"), each("output_tokens"),
        t["ollama_seconds"], t["load_seconds"])


def classify_movie(movie, model=DEFAULT_MODEL, question=DEFAULT_QUESTION, options=(), timeout=600, stats=None):
    """call_ollama_movie.bash on a movie file. Returns ({label: bool} for LABELS, seconds), or
    (None, seconds) when Ollama could not answer. options: extra script options, e.g. ["-n", "4"].
    stats: a list to append each Ollama call's stats to (see _run); summarize() and describe() total them."""
    t0 = time.monotonic()
    answer = _run([HERE / "call_ollama_movie.bash"] + list(options) + [model, question, movie], timeout, stats)
    secs = time.monotonic() - t0
    if answer is None:
        return None, secs
    return {k: answer.get(k) is True for k in LABELS}, secs


def classify_images(images, model=DEFAULT_MODEL, question=DEFAULT_QUESTION, timeout=300, stats=None):
    """call_ollama.bash on image files. Returns {label: bool} for LABELS, or None. stats: as classify_movie."""
    answer = _run([HERE / "call_ollama.bash", model, question] + list(images), timeout, stats)
    return None if answer is None else {k: answer.get(k) is True for k in LABELS}


def cute_text(image, model=DEFAULT_MODEL, question="", timeout=60, stats=None, label="", context=""):
    """cute_ollama.bash on one photo: a short, cute sentence about it to say out loud, e.g. "A tabby cat is
    sitting by the door, looking in.", or None. question: empty = cute_question in ollama_common.bash.
    label: what the camera found, put in for the question's {label} (e.g. "cat"; empty = "animal").
    context: facts about right now for its {context} (e.g. "it is evening; it is dark outside").
    stats: as classify_movie."""
    args = [question, label, context] if context else [question, label] if label else [question] if question else []
    answer = _run([HERE / "cute_ollama.bash", model, image] + args, timeout, stats)
    text = answer and answer.get("text")
    if not text:
        return None
    # no emoji or other pictographs: the sentence is spoken (a speaker may read out "paw prints")
    text = re.sub(r"[\U0001F000-\U0001FFFF\u2600-\u27BF\u2B00-\u2BFF\uFE0F\u200D]", "", text)
    return re.sub(r"\s+([.,!?])", r"\1", re.sub(r"\s{2,}", " ", text)).strip() or None


def pick_representative(images, labels, model=DEFAULT_MODEL, question=DEFAULT_QUESTION, stats=None):
    """Of images (best first), the first that shows what the movie matched, for the event's preview
    picture: one call per image until one shows a matched label (usually the first). "animal" and
    "legs" come with the specific labels, so those are looked for when there are any. Returns
    (index into images, calls); the first image if none confirms it or the calls fail.
    stats: as classify_movie."""
    hits = [k for k, v in labels.items() if v]
    wanted = [h for h in hits if h not in ("animal", "legs")] or hits
    if len(images) < 2 or not wanted:
        return 0, 0
    for i, image in enumerate(images):
        found = classify_images([image], model, question, stats=stats)
        if found is None:
            return 0, i + 1
        if any(found.get(w) for w in wanted):
            return i, i + 1
    return 0, len(images)


def setting(name):
    """A setting from ollama_common.bash (after this machine's ollama_env_props.bash and the environment),
    e.g. setting("cmo_server"). Both cameras read shared settings this way, so they always agree."""
    r = subprocess.run(["bash", "-c", 'source "$1/ollama_common.bash" >/dev/null 2>&1; printf %s "${!2}"', "_",
                        str(HERE), name], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       env=dict(os.environ, quiet="true"))
    return r.stdout.decode().strip()


def code():
    """This code and its version, e.g. "cmo_ollama:1.3.0" (see code_version in ollama_common.bash)."""
    return "cmo_ollama:" + (setting("cmo_ollama_version") or "unknown")


def check_setup():
    """An error message if the scripts can't run here (missing tools or settings), else None."""
    import shutil
    missing = [t for t in ("jq", "curl", "base64", "ffmpeg", "ffprobe", "python3") if not shutil.which(t)]
    if missing:
        return "cmo_ollama needs " + ", ".join(missing) + " on the PATH"
    if not (HERE / "ollama_common.bash").exists():
        return "{} is missing: git pull cmo_ollama".format(HERE / "ollama_common.bash")
    return None
