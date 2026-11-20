# cmo_ollama

> Part of the [Private AI home camera system](https://github.com/markmckellar/cmo): this repo is the AI step. The other parts: [cmo_client](https://github.com/markmckellar/cmo_client) · [cmo_server](https://github.com/markmckellar/cmo_server) · [cmo_vue_client](https://github.com/markmckellar/cmo_vue_client).

Bash scripts for asking [ollama](https://ollama.com) vision models questions about
still images and security-camera movie clips from the cmo cat cam (the pet door
camera). The main job is answering "is there a person / cat / dog / raccoon /
animal in this clip?" as JSON so other scripts can act on it.

## Contents

- [Requirements](#requirements)
- [Setup](#setup)
- [The scripts](#the-scripts)
- [How it works](#how-it-works)
  - [call_ollama.bash](#call_ollamabash--ask-about-images)
  - [call_ollama_movie.bash](#call_ollama_moviebash--ask-about-a-movie-clip)
  - [Grid mode vs frames mode](#grid-mode-vs-frames-mode)
- [Configuration reference](#configuration-reference)
- [Stats: context, tokens and time](#stats-context-tokens-and-time)
- [Examples](#examples)
- [Used by the cameras](#used-by-the-cameras)
- [Test data](#test-data)
- [Model notes](#model-notes)
- [Troubleshooting](#troubleshooting)
- [Versions](#versions)

## Requirements

| Tool | Used by | Notes |
| --- | --- | --- |
| ollama | everything | Running somewhere on the network, with at least one vision model pulled |
| `curl` | everything | Calls the ollama HTTP API and downloads image URLs |
| `jq` | everything | Builds the request JSON and parses the response |
| `base64` (coreutils) | `call_ollama.bash` | Encodes the images for the request |
| `ffmpeg`, `ffprobe` | `call_ollama_movie.bash` | Picks frames out of the clip and builds the grid image |
| `cute_ollama.bash` | Asks for one short, cute sentence about a photo, to say out loud (`{"text": "..."}`). Shrinks the photo to 640 wide first (about 1,150 prompt tokens, 1.3 s). The question is `cute_question` in `ollama_common.bash` (a pet door on a porch; its `{label}` is the optional 4th argument, e.g. `cat`); from Python, `call_ollama.cute_text(image, label="cat")`. The pet door's Google Home announcements use it. |
| `jo` | `time_models.bash` | Only used to unload each model after timing it |

On Debian/Ubuntu/Raspberry Pi OS:

```bash
sudo apt install curl jq ffmpeg jo
```

Pull at least one vision model on the ollama server:

```bash
ollama pull qwen2.5vl:7b
ollama pull qwen3-vl:8b
```

## Setup

1. The settings are in `ollama_common.bash`, which is tracked by git and the same on every machine:
   the Ollama server (`api`), the questions, logging and the tuning defaults. Both cameras use it, so
   they ask the same question the same way, and a `git pull` updates every machine. Change a setting
   there, commit it, and pull it on the other machines.

2. A machine that has to differ (for example a test machine with its own Ollama) copies the template and
   sets only what differs. Most machines don't need this:

   ```bash
   cp ollama_env_props.bash.template ollama_env_props.bash    # not tracked by git
   # then in it, e.g.:  api="http://localhost:11434"
   ```

   `ollama_common.bash` sources `ollama_env_props.bash` last, so its settings win. If ollama is on another
   machine it has to listen on the network, not just localhost. Set `OLLAMA_HOST=0.0.0.0` in the ollama
   service environment (`sudo systemctl edit ollama`) and restart it.

3. Check that you can reach the server and see what models it has:

   ```bash
   source ollama_common.bash
   curl "$api/api/version"
   curl -s "$api/api/tags" | jq -r '.models[].name'
   ```

4. Try a single image:

   ```bash
   ./call_ollama.bash "qwen2.5vl:7b" "What animal is in this picture?" ../cmo_test_data/cat.jpg
   ```

## The scripts

| Script | What it does |
| --- | --- |
| `call_ollama.bash` | Sends one or more images (local files or URLs) and a question to a model. Prints the answer as compact JSON. |
| `call_ollama_movie.bash` | Picks representative frames from an mp4 and asks a question about them through `call_ollama.bash`. |
| `compare_modes.bash` | Runs `call_ollama_movie.bash` in grid and frames mode over a set of movies and prints a table of tokens, seconds and answers. |
| `time_models.bash` | Runs one question and image against every model on the server, unloading each model afterwards. |
| `get_label_samples.bash` | Downloads sample clips for each label from the cat cam server, gently, into `cmo_test_data/new_samples/` for hand labeling. |
| `dark_or_light.bash` | Prints `light` or `dark` based on today's sunrise and sunset from wttr.in. |
| `ollama_common.bash` | Settings and the `logMessage` function, the same on every machine. Sourced by the other scripts. |
| `ollama_env_props.bash` | Optional, not in git: a machine's own differences, from `ollama_env_props.bash.template`. |
| `call_ollama.py` | Runs these scripts from Python. The cameras use it (see [Used by the cameras](#used-by-the-cameras)). |
| `release.bash` | Tags a new version (see [Versions](#versions)). |

## How it works

### call_ollama.bash — ask about images

```
call_ollama.bash <model> <question> <image-or-url> [<image-or-url> ...]
```

1. Sources `ollama_common.bash` to get `api`, the logging settings and
   `person_animal_question`.
2. If `<question>` is the literal word `person_animal_question`, it is replaced
   with the standard person/animal question from `ollama_common.bash`.
3. Each image is downloaded first if it starts with `http`, then base64 encoded
   into a JSON array.
4. `jq` builds a request for `POST $api/api/generate` with:
   - `stream: false`, so the whole answer comes back in one response
   - `format: "json"`, so the model has to answer in JSON
   - `think: false`, so thinking models (qwen3-vl) don't spend time reasoning
   - `options.num_ctx` (context window) and `options.num_predict` (max output tokens)
5. `curl` sends the request with a timeout (`ollama_timeout`, 180s by default).
6. If a `model_outputs/` directory exists, the raw ollama response is saved
   there as `<model>_response.json`, which helps with debugging.
7. The answer is taken from `.response`, or from `.thinking` if `.response` is
   empty (see [Model notes](#model-notes)). Any ```` ```json ```` fences are
   removed and the JSON is compacted to one line.
8. Timing and token counts are logged as a `stats=` line, for example
   `{"model":"qwen3-vl:8b","image_count":1,"num_ctx":2048,"prompt_tokens":1469,"output_tokens":33,"total_seconds":1.7,"load_seconds":0}`.
   If `ollama_stats_file` is set, the same JSON line is also appended there (the
   cameras and the test scripts use this to keep the numbers, see
   [Stats](#stats-context-tokens-and-time)). If the prompt and the answer filled the
   whole context window, a warning is logged, because the images or the answer
   were probably cut off.

**Output:** the model's JSON answer on stdout, for example

```json
{"legs":false,"person":false,"cat":false,"dog":false,"raccoon":true,"animal":true}
```

**On failure** (server unreachable, timeout, ollama error, or an answer that
isn't JSON) it prints `{}` and exits with status 1. The reason only shows up if
logging is turned on (`quiet=false`), see [Troubleshooting](#troubleshooting).

### call_ollama_movie.bash — ask about a movie clip

```
call_ollama_movie.bash [-m grid|frames] [-n frame_count] [-s motion|mixed|split|window|thumbnail] [-r ranges] [-c] <model> <question> <movie-file>
```

How frames are picked (`-s`, default `split`) and limited to parts of the clip (`-r`) is described at
the top of the script. The steps below are the `thumbnail` picker, the simplest one.

1. `ffprobe` counts the frames in the clip. It reads `nb_frames` from the
   container, or counts packets if the container doesn't record it.
2. The clip is split into `frame_count` equal segments (4 by default). ffmpeg's
   `thumbnail` filter picks the most representative frame from each segment,
   so the frames cover the whole clip and not just the start.
3. Depending on the mode:
   - **grid** (default): the frames are scaled and tiled into one JPEG with
     white lines between them (4 frames make a 2x2 grid, 6 make a 3x2 grid, and so on).
     The question gets a prefix explaining that the image is a grid of frames in
     time order and that something counts as present if it is in any frame.
   - **frames**: each frame is sent as its own image.
4. The image or images and the question go to `call_ollama.bash`, and its
   JSON answer is printed.

If no frames can be read from the movie, it prints `{}`. The script always exits 0, so check for `{}` rather than the exit
status.

All temporary files are in a `mktemp -d` directory that is removed on exit.

### Cropping to the motion (-c)

With `-c` (or `ollama_motion_crop=true`), `pick_motion_frames.py --select box` finds the part of the
picture where something moved during the clip, and every frame is cropped to it and scaled back up to
the frame's width before the grid is made. The prompt then says the frames are zoomed in. The box has
the frame's shape, is at least 0.3 of it, and is padded 1.3x. Brief movement elsewhere, like a car
passing in the street, is left out when something else moved for much longer. Nothing is cropped when
nothing moved or the box would be most of the picture.

It is for cameras where people and animals are small, like the porch camera. In its default 8-frame
grid each frame is 512 px wide, and a cat on the porch is about 25x45 px. qwen3-vl turns the image
into tokens of about 32x32 px, so the cat is 1-2 tokens: the model sees an animal but not which one.
On 2026-10-14 it called a grey tabby dog or raccoon in 7 of 9 porch events. The porch runs
`-s motion -c` (`classifier.movie_options` in cmo_client's `porch_cam.properties`); see
[Test data](#test-data) for how it scored.

### Grid mode vs frames mode

Every image costs prompt tokens, and with several separate frames the prompt can
go past `num_ctx`. When that happens ollama silently drops part of the input.
The default context (2048) fits grid mode only: run frames mode with
`ollama_num_ctx=6000` or so.
Measured on a 41-clip sample with 4 frames:

| | grid | frames |
| --- | --- | --- |
| Prompt tokens | ~1,180 | ~4,200 |
| Speed | about 2x faster | |
| qwen2.5vl:7b accuracy | noticeably better | |
| qwen3-vl:8b accuracy | about the same, sometimes reports legs or a person that aren't there | |

Grid mode is the default. Use `-m frames` if a model handles separate images
better, or if you need full resolution for each frame. You can run
`compare_modes.bash` on your own clips to check.

## Configuration reference

All of these are in `ollama_common.bash` (the same on every machine). A machine's own
`ollama_env_props.bash` can override any of them, and any can be set as an environment
variable for a single run.

| Variable | Default | Meaning |
| --- | --- | --- |
| `api` | `http://localhost:11434` | ollama base URL (a camera on another machine sets the GPU desktop's address in its `ollama_env_props.bash`) |
| `cmo_test_data` | `../cmo_test_data` (next to this repo) | Where the private test clips and hand labels are; used by `score_models.py` and `get_label_samples.bash` |
| `quiet` | `true` | Set to `false` to turn on log messages. Can be set per run: `quiet=false ./call_ollama.bash ...` |
| `ollama_log_file` | `~/logs/call_ollama.log` | Where log messages go (`CMO_LOG_DIR` moves it). Set `/dev/stderr` to see them in the terminal |
| `ollama_log_tag` | `OLLAMA_LOG cmo_ollama:<version>` | Tag on every log line |
| `person_animal_question` | see template | The standard legs/person/cat/dog/raccoon/animal JSON question |
| `ollama_num_ctx` | `2048` | Context window sent with each request. The prompt (a camera's 4-frame grid and the question: ~1,250–1,500 tokens for the porch's 16:9 frames, ~1,820 for the pet door's 4:3 ones) plus the answer must fit. 2048 is also the smallest ollama uses: a smaller value is raised to 2048 when the model loads. Raise it for frames mode or more frames |
| `ollama_num_predict` | `256` | Max tokens the model may generate. Stops runaway answers that would otherwise run until the timeout |
| `ollama_timeout` | `180` | Seconds to wait for ollama |
| `ollama_stats_file` | unset | If set, one JSON line of stats per call is appended here |
| `ollama_movie_mode` | `grid` | Default for `-m` |
| `ollama_movie_frames` | `4` | Default for `-n` |
| `ollama_grid_max_width` | `1024` | Max pixel width of the grid image |
| `ollama_frame_select` | `split` | Default for `-s` |
| `ollama_frame_ranges` | none | Default for `-r` |
| `ollama_motion_crop` | `false` | `true` for `-c`: crop the frames to where something moved |
| `ollama_recheck_animals` | `true` | When an answer has a person and an animal, ask again about the animals only, told to ignore people, and keep an animal only if that confirms it |
| `person_animal_recheck_question` | built into `call_ollama_movie.bash` | The question for that second call |
| `ollama_keep_alive` | ollama's (5 minutes) | How long ollama keeps the model loaded after a call, e.g. `30m` (the cameras set this) |

## Stats: context, tokens and time

Every Ollama call's numbers are kept in three places:

- **`call_ollama.log`** (`~/logs` on each machine): a `stats=` line per call, see step 8 of
  `call_ollama.bash` above. The log rolls over at 5 MB.
- **Camera events:** cmo_watch (both cameras) passes `stats=` to `call_ollama.py`, saves the
  numbers in the event and writes them on the event's line in the camera's log
  (`pet_watch.log`, `porch_watch.log`):
  ```
  event: 22:59:48 26.3s -> MATCH legs,person (54.1s; ollama: 2 calls, context 2048, prompt 1469+1466 tokens, output 33+21 tokens, 3.4s (load 0.0s))
  ```
  In the event's `me_data.json` → `cmo_watch.llm`: `seconds` (the whole classification as
  the camera saw it: making the grid, every call), `ollama` (the totals from
  `call_ollama.summarize()`: calls, num_ctx, prompt_tokens, output_tokens,
  ollama_seconds, load_seconds), `ollama_calls` (each call's stats line) and the same
  two for the preview-picture calls (`rep_frame_ollama`, `rep_frame_ollama_calls`).
- **Tests:** `model_agreement.bash` saves `seconds`, `num_ctx`, `prompt_tokens`,
  `output_tokens` and `calls` on every result line, `model_agreement_report.py` shows the
  average tokens per model, and `compare_modes.bash` prints them per movie and mode.

## Examples

### Single images

```bash
# A local file
./call_ollama.bash "qwen2.5vl:7b" "What animal is in this picture?" ../cmo_test_data/cat.jpg

# An image URL from the cat cam
./call_ollama.bash "qwen2.5vl:3b" "What animal is in this picture?" \
  "https://your-server/catcam/data/pet_door/20250810/20250810_004012_0136/me_rep_image.jpg"

# The standard person/animal question
./call_ollama.bash "qwen3-vl:8b" "person_animal_question" ../cmo_test_data/cat.jpg

# Two images in one request
./call_ollama.bash "qwen2.5vl:7b" "Is there a cat in both pictures?" \
  ../cmo_test_data/cat.jpg \
  ../cmo_test_data/person.jpg
```

### A cute sentence

```bash
./cute_ollama.bash qwen3-vl:8b ../cmo_test_data/cat.jpg
# {"text":"A tabby cat is sitting by the door, looking in."}
```

It runs at temperature 0.7 with a new seed each time, so the same picture gets a different sentence on
another run (set `ollama_temperature=0 ollama_seed=42` for a repeatable one). A third argument replaces the
question.

### Movie clips

```bash
# Default: 4 frames in a 2x2 grid
./call_ollama_movie.bash "qwen3-vl:8b" "person_animal_question" ../cmo_test_data/raccoon.mp4

# 6 frames sent as separate images
./call_ollama_movie.bash -m frames -n 6 "qwen2.5vl:7b" "person_animal_question" ../cmo_test_data/raccoon.mp4

# 9 frames in a 3x3 grid, wider grid image
ollama_grid_max_width=1536 ./call_ollama_movie.bash -n 9 "qwen2.5vl:7b" "person_animal_question" ../cmo_test_data/cat.mp4

# Your own question
./call_ollama_movie.bash "qwen2.5vl:7b" \
  "Is a cat going through the pet door? Respond in JSON with the key 'cat_in_door' as true or false." \
  ../cmo_test_data/cat.mp4
```

### Using the answer in a script

```bash
answer=$(./call_ollama_movie.bash "qwen2.5vl:7b" "person_animal_question" "$movie")
if [ "$answer" = "{}" ]; then
  echo "ollama call failed"
elif [ "$(echo "$answer" | jq -r '.raccoon')" = "true" ]; then
  echo "raccoon in $movie"
fi
```

### Batch runs

```bash
# Every hand-labeled cat clip, print the file name and answer
for movie in ../cmo_test_data/labeled/cat/*.mp4; do
  echo "$movie $(./call_ollama_movie.bash "qwen2.5vl:7b" "person_animal_question" "$movie")"
done

# Only the clips where a raccoon was seen
for movie in ../cmo_test_data/raccoons/*.mp4; do
  answer=$(./call_ollama_movie.bash "qwen2.5vl:7b" "person_animal_question" "$movie")
  [ "$(echo "$answer" | jq -r '.raccoon')" = "true" ] && echo "$movie"
done
```

### Logging and stats

```bash
# Show what each step is doing, in the terminal
quiet=false ollama_log_file=/dev/stderr ./call_ollama_movie.bash "qwen3-vl:8b" "person_animal_question" ../cmo_test_data/raccoon.mp4
```

`ollama_common.bash` sets `quiet=${quiet:-true}`, so a `quiet` set in the
environment wins. Logging stays off unless you ask for it (the cameras turn it on
for their calls). Messages go to `~/logs/call_ollama.log`; add
`ollama_log_file=/dev/stderr` to see them in the terminal instead.

```bash
# Collect token and timing stats for a batch
export ollama_stats_file=stats.jsonl
for movie in ../cmo_test_data/raccoon_0*.mp4; do
  ./call_ollama_movie.bash "qwen2.5vl:7b" "person_animal_question" "$movie" > /dev/null
done
jq -s 'map(.total_seconds) | add / length' stats.jsonl   # average seconds per call
```

### Comparing modes and models

```bash
# Grid vs frames: one tab separated line per movie and mode
./compare_modes.bash "qwen2.5vl:7b" "person_animal_question" ../cmo_test_data/*.mp4 | column -t -s $'\t'

# Every model on the server with the same image (slow; each model is loaded and unloaded)
./time_models.bash "List all the humans or animals in the picture as a comma separated list." \
  ../cmo_test_data/cat.jpg
```

### Other

```bash
# Is it day or night where this machine is?
./dark_or_light.bash

# Download 10 new clips per label from the cat cam server into ../cmo_test_data/new_samples,
# skipping ones already labeled; label them by hand, then move them into labeled/
catcam_skip=../cmo_test_data/labeled/labels.tsv ./get_label_samples.bash 10
```

## Used by the cameras

Both cameras classify their motion events with these scripts, so they answer the same question the
same way, and a change here is tested once, on the labeled clips, for both:

- both run `cmo_watch.py` from the [cmo_client](https://github.com/markmckellar/cmo_client) repo
  (`~/dev/cmo_client`): the porch camera on mckada (`porch_cam.properties`), the pet door on its Pi
  (`pet_door.properties`)

Each camera cuts an event's movie and calls `call_ollama_movie.bash` on it through `call_ollama.py`,
then `call_ollama.bash` on single frames to choose the event's preview picture. Both expect this folder
at `~/dev/cmo_ollama` (`classifier.cmo_ollama_dir` in a camera's properties), and take the Ollama
server and the question from its `ollama_common.bash`, so both ask the same question of the same server.

```python
import os, sys
sys.path.insert(0, os.path.expanduser("~/dev/cmo_ollama"))
import call_ollama
labels, seconds = call_ollama.classify_movie("me_movie.mp4", "qwen3-vl:8b")
# {"legs": false, "person": true, "cat": false, "dog": false, "raccoon": false, "animal": false},
# or None when ollama could not answer
```

`call_ollama.py` runs on Python 3.7 (the pet door Pi) and newer. When an animal is reported together
with a person, `call_ollama_movie.bash` checks the animal again with people ignored
(`ollama_recheck_animals`); on the labeled clips this changed none of the 5 real person-and-dog clips.

## Test data

The test clips and hand labels are in a separate **private** repo, `cmo_test_data`, because they show real
people and places. The scripts look for it next to this repo (`~/dev/cmo_test_data` beside
`~/dev/cmo_ollama`); set `cmo_test_data` to put it elsewhere. Without it everything still runs on your own
images and clips; only the scoring needs the labels.

| Path | Contents |
| --- | --- |
| `cmo_test_data/raccoon.mp4`, `raccoon_01..04.mp4`, `raccoons/` | Raccoon clips |
| `cmo_test_data/cat.mp4` | Cat clip |
| `cmo_test_data/empty.mp4` | A clip with nothing in it, for checking false positives |
| `cmo_test_data/labeled/` | 140 hand-labeled clips from both cameras and `labels.tsv` (see its README) |
| `cmo_test_data/cat.jpg`, `person.jpg` | Pet door stills: a cat, and a person walking past |
| `model_outputs/` | Raw ollama response from the last call to each model (here, gitignored) |

Score a setting on the labeled clips by making a manifest from `labels.tsv` (me_name, category,
server_labels, file per line), running `model_agreement.bash` on it and then `score_models.py`.
Settings go in the environment, e.g. `ollama_frame_select=motion ollama_motion_crop=true`.

Motion crop, qwen3-vl:8b, 2026-10-14, clips with all 6 labels right:

| | default (`split`, no crop) | `-s motion -c` |
| --- | --- | --- |
| porch (21 clips) | 11 | 19 |
| pet door (118 clips) | 95 | 94 |
| prompt tokens, average | 1,868 | 1,337 |

On the porch the crop fixed all 7 misnamed cats and a missed dog walker and broke nothing; the two still
wrong are the cat held against a dark coat and a far-away dog walker (wrong both ways). On the pet door,
where the cat fills the frame, it fixed 8 clips and broke 9 (mostly cats at night, plus 2 raccoons and
a person), so the pet door stays on the default.

## Model notes

- **qwen2.5vl:7b** is the most reliable for the person/animal question, and
  works best in grid mode.
- **qwen2.5vl:3b** is faster and good enough for single images, but less accurate.
- **qwen3-vl:8b** gives similar results in both modes. In grid mode it
  sometimes reports legs or a person that aren't there. On some ollama versions
  it returns its answer in `.thinking` and leaves `.response` empty, even with
  `think: false`. `call_ollama.bash` handles this by falling back to `.thinking`.
- gemma3:1b and tinydolphin weren't useful. Larger models like llama3.2-vision
  work but are slow.
- Very occasionally a model keeps generating and never stops. `num_predict=256`
  caps that, and the 180s timeout catches anything else.

## Troubleshooting

**I just get `{}`.** `call_ollama.bash` failed, and logging is off so the
reason is hidden. Run it again with `quiet=false` in front of the command to
see the log. Common causes:

- ollama isn't running. `curl "$api/api/version"` fails with *Couldn't connect
  to server*. Start it with `sudo systemctl start ollama`, or
  `sudo systemctl enable --now ollama` to also start it at boot.
- `api` points at the machine's LAN address but ollama only listens on
  localhost. Use `api="http://localhost:11434"` or set `OLLAMA_HOST=0.0.0.0`
  on the server.
- The model isn't pulled. The log shows `ollama returned error : model ... not found`.
  Run `ollama pull <model>`.
- The request timed out. The first call to a model includes loading it into
  memory. Raise `ollama_timeout` or try again.
- The movie has no readable frames (`could not read any frames` in the log).

**The answers look wrong for some frames.** Look for the `WARNING : prompt N + output N
tokens filled the context` line in the log. If it's there, the images or the answer were
cut off. Use grid mode, fewer frames, or a bigger `ollama_num_ctx`.

**What did the model actually return?** Create a `model_outputs/` directory.
Each call then saves the raw response to
`model_outputs/<model>_response.json`.

## Versions

Every cmo repo (cmo_ollama, cmo_client, cmo_server, cmo_vue_client) is versioned the same way:
`<repo>:MAJOR.MINOR.PATCH`, such as `cmo_ollama:1.3.0`, taken from the repo's git tags.

| Version | Means |
| --- | --- |
| `1.3.0` | exactly the `v1.3.0` release |
| `1.3.0+4` | 4 commits after it, not released yet |
| `1.3.0+4.dirty` (`1.3.0+dirty` on the release itself) | also uncommitted changes in the checkout |
| `unknown` | not a git checkout, or no release tag yet |

Here it is worked out by `code_version` in `ollama_common.bash`, as `cmo_ollama_version`. It is in the
tag of every log line (`OLLAMA_LOG cmo_ollama:1.3.0`) and in every `stats=` line as `"code"`, which the
cameras keep in each event's `me_data.json`. `call_ollama.code()` returns it for Python.

To release, commit everything, then:

```bash
./release.bash patch "fix the raccoon prompt"   # 1.3.0 -> 1.3.1: a fix
./release.bash minor "motion crop"              # 1.3.0 -> 1.4.0: something new
./release.bash major "new me_data.json layout"  # 1.3.0 -> 2.0.0: breaks what reads it
git push origin HEAD v1.4.0                     # it prints this
```

A machine shows the new version after a `git pull` (the cameras: and a restart).
