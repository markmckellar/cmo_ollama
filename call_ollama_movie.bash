#!/usr/bin/env bash
#
# Ask an ollama vision model a question about a movie clip.
#
# Usage: call_ollama_movie.bash [-m grid|frames] [-n frame_count] [-s motion|mixed|split|window|thumbnail] [-r ranges] [-c] <model> <question> <movie-file>
#
# frame_count frames are picked from the clip with -s:
#   motion    - pick_motion_frames.py finds the frames that differ
#               from the clip's background and spreads the picks over them, so
#               a cat that is only in the clip for a second still gets picked
#   mixed     - half the frames from motion, the rest closest to the average
#               of equal parts of the clip (see pick_motion_frames.py)
#   split     - (default) frame_count motion frames and frame_count average frames; in grid
#               mode they become two grids, motion on top, stacked in one image
#   window    - like split, but every frame is inside the event window: from the first
#               to the last burst of activity (see pick_motion_frames.py)
#   thumbnail - the clip is split into frame_count equal segments and ffmpeg's
#               thumbnail filter picks the most representative frame from each.
#               In a mostly empty clip that is usually an empty frame.
# -r limits the picks to frames inside the ranges, comma separated, such as
# 22-45,67-90 (seconds) or 900f-1080f (movie frame numbers). Not used with thumbnail.
# -c crops every frame to the part of the picture where something moved (pick_motion_frames.py
# --select box) and scales it back up to the frame's size, so something small and far away, like
# a cat on the porch seen from the eaves, is big enough for the model to tell what it is. Nothing
# is cropped when nothing moved or the movement covers most of the picture. Not used with thumbnail.
# Then either:
#   grid   - (default) the frames are tiled into one image and sent as a
#            single image, with the question prefixed by a description of the grid
#   frames - each frame is sent as a separate image
#
# <question> may be a question name from ollama_common.bash, such as
# person_animal_question or person_animal_question_v2.
#
# Optional settings (set in ollama_common.bash, or the environment for one run):
#   ollama_movie_mode      default for -m (grid)
#   ollama_movie_frames    default for -n (4)
#   ollama_grid_max_width  max pixel width of the grid image (1024)
#   ollama_frame_select    default for -s (split)
#   ollama_frame_ranges    default for -r (none, the whole clip)
#   ollama_motion_crop     true for -c (false)
#   ollama_night_brighten  brighten frames darker than ollama_night_threshold (true)
#   ollama_night_threshold average brightness 0-255 below which a frame is night (60)
#   ollama_recheck_animals when the answer has a person and an animal, ask again about the
#                          animals only, told to ignore people, and keep an animal only if
#                          that answer confirms it (true). The models sometimes call a
#                          small, dark or partly visible person a dog or an animal.
#   person_animal_recheck_question  the question for that second call (see below)

script_path="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$script_path/ollama_common.bash"

usage() {
  echo "Usage: $0 [-m grid|frames] [-n frame_count] [-s motion|mixed|split|window|thumbnail] [-r ranges] [-c] <model> <question> <movie-file>" >&2
  exit 1
}

mode=${ollama_movie_mode:-grid}
frame_count=${ollama_movie_frames:-4}
grid_max_width=${ollama_grid_max_width:-1024}
select=${ollama_frame_select:-split}
frame_ranges=${ollama_frame_ranges:-}
motion_crop=${ollama_motion_crop:-false}
night_brighten=${ollama_night_brighten:-true}
night_threshold=${ollama_night_threshold:-60}
recheck_animals=${ollama_recheck_animals:-true}
recheck_question=${person_animal_recheck_question:-"A person, or part of a person, is in this image. Ignore every person and every human body part, including people that are small, far away, dark, crouching or partly hidden, and their legs, feet and hands. Only a separate, non-human animal counts. cat: true if a cat is visible. dog: true if a dog is visible. raccoon: true if a raccoon is visible (grey fur, black mask around the eyes, ringed tail). animal: true if a cat, dog, raccoon or any other mammal is visible; insects and spiders do not count. Respond in JSON with exactly these keys and true or false values: cat, dog, raccoon, animal."}

while getopts "m:n:s:r:c" opt; do
  case $opt in
    m) mode=$OPTARG ;;
    n) frame_count=$OPTARG ;;
    s) select=$OPTARG ;;
    r) frame_ranges=$OPTARG ;;
    c) motion_crop=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

[ "$#" -eq 3 ] || usage
[[ "$mode" == "grid" || "$mode" == "frames" ]] || usage
[[ "$select" =~ ^(motion|mixed|split|window|thumbnail)$ ]] || usage
[[ "$frame_count" =~ ^[1-9][0-9]*$ ]] || usage
[[ -z "$frame_ranges" || "$select" != "thumbnail" ]] || usage
[[ -z "$frame_ranges" || "$frame_ranges" =~ ^[0-9.f,-]+$ ]] || usage

model=$1
question=$2
movie_file=$3

if [[ "$question" =~ ^person_animal_question[a-z0-9_]*$ && -n "${!question}" ]]; then
  question="${!question}"
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

logMessage "$0 : START : model=$model mode=$mode frame_count=$frame_count select=$select crop=$motion_crop movie=$movie_file"

# Frames in the clip. nb_frames is missing from some containers, so fall back
# to counting packets.
total_frames=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$movie_file")
if ! [[ "$total_frames" =~ ^[0-9]+$ ]]; then
  total_frames=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$movie_file")
fi
if ! [[ "$total_frames" =~ ^[0-9]+$ ]] || [ "$total_frames" -eq 0 ]; then
  logMessage "$0 : could not read any frames from $movie_file"
  echo "{}"
  exit 0
fi

pick_thumbnail_frames() {
  local segment_frames=$(( total_frames / frame_count ))
  [ "$segment_frames" -ge 1 ] || segment_frames=1
  logMessage "$0 : total_frames=$total_frames segment_frames=$segment_frames"
  ffmpeg -loglevel error -i "$movie_file" -vf "thumbnail=n=$segment_frames" -fps_mode vfr \
    -frames:v "$frame_count" "$work_dir/frame_%02d.png"
}

# split: frame_count motion frames followed by frame_count average frames
pick_times() {
  local range_args=()
  [ -n "$frame_ranges" ] && range_args=(--ranges "$frame_ranges")
  if [[ "$select" == "window" ]]; then
    # frame_count movement frames then frame_count average frames, inside the event window
    "$script_path/pick_motion_frames.py" "${range_args[@]}" --select window "$movie_file" "$frame_count"
  elif [[ "$select" == "split" ]]; then
    "$script_path/pick_motion_frames.py" "${range_args[@]}" --select motion "$movie_file" "$frame_count" &&
      "$script_path/pick_motion_frames.py" "${range_args[@]}" --select average "$movie_file" "$frame_count"
  else
    "$script_path/pick_motion_frames.py" "${range_args[@]}" --select "$select" "$movie_file" "$frame_count"
  fi
}

if [[ "$select" != "thumbnail" ]] && times=$(pick_times); then
  logMessage "$0 : $select frames at <$(echo $times)> seconds"
  i=0
  for t in $times; do
    i=$((i + 1))
    ffmpeg -loglevel error -ss "$t" -i "$movie_file" -frames:v 1 "$work_dir/$(printf 'frame_%02d.png' "$i")"
  done
elif [ -n "$frame_ranges" ]; then
  # never fall back to the whole clip when the caller asked for specific ranges
  logMessage "$0 : no frames picked from $movie_file in $frame_ranges"
  echo "{}"
  exit 0
else
  [[ "$select" != "thumbnail" ]] && logMessage "$0 : $select frame picking failed, using thumbnail"
  pick_thumbnail_frames
fi

frames=("$work_dir"/frame_*.png)
if [ ! -e "${frames[0]}" ]; then
  logMessage "$0 : no frames extracted from $movie_file"
  echo "{}"
  exit 0
fi
logMessage "$0 : extracted ${#frames[@]} frames"

# -c: crop to where something moved, scaled back up to the frame's width
zoomed=false
if [[ "$motion_crop" == "true" && "$select" != "thumbnail" ]]; then
  range_args=()
  [ -n "$frame_ranges" ] && range_args=(--ranges "$frame_ranges")
  box=$("$script_path/pick_motion_frames.py" "${range_args[@]}" --select box "$movie_file" 1)
  if [[ "$box" =~ ^[0-9.]+\ [0-9.]+\ [0-9.]+\ [0-9.]+$ ]]; then
    read -r box_x box_y box_w box_h <<< "$box"
    for frame in "${frames[@]}"; do
      ffmpeg -loglevel error -y -i "$frame" \
        -vf "crop=trunc(iw*$box_w/2)*2:trunc(ih*$box_h/2)*2:iw*$box_x:ih*$box_y,scale=$(ffprobe -v error -show_entries stream=width -of csv=p=0 "$frame"):-2:flags=lanczos" \
        "$frame.crop.png" && mv "$frame.crop.png" "$frame"
    done
    zoomed=true
    logMessage "$0 : cropped to x y width height <$box>"
  else
    logMessage "$0 : no crop, the movement is most of the picture or there is none"
  fi
fi
zoom_desc=""
[[ "$zoomed" == "true" ]] && zoom_desc=" Every frame is zoomed in on the part of the picture where something moved."

# Night frames are very dark (average brightness 14-37 out of 255, day frames
# 84-123) and the model misses cats in them, so lift the shadows with a gamma
# curve. Checked per frame because a light can come on during a clip.
if [[ "$night_brighten" == "true" ]]; then
  for frame in "${frames[@]}"; do
    brightness=$(ffmpeg -loglevel error -i "$frame" -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" -f null - |
      awk -F= '/YAVG/ {printf "%d", $2}')
    if [ -n "$brightness" ] && [ "$brightness" -lt "$night_threshold" ]; then
      ffmpeg -loglevel error -y -i "$frame" -vf "eq=gamma=1.8:brightness=0.1" "$frame.bright.png" &&
        mv "$frame.bright.png" "$frame"
      logMessage "$0 : brightened $(basename "$frame") (brightness $brightness)"
    fi
  done
fi

# make_grid <output> <frame>... : tile the frames into a square-ish grid with
# white lines between them. Sets grid_rows and grid_cols.
make_grid() {
  local output=$1
  shift
  local count=$# list="$work_dir/grid_list.txt" frame
  grid_cols=1
  while [ $(( grid_cols * grid_cols )) -lt "$count" ]; do grid_cols=$(( grid_cols + 1 )); done
  grid_rows=$(( (count + grid_cols - 1) / grid_cols ))
  local tile_width=$(( grid_max_width / grid_cols ))
  : > "$list"
  for frame in "$@"; do echo "file '$frame'" >> "$list"; done
  ffmpeg -loglevel error -f concat -safe 0 -i "$list" \
    -vf "scale=w='min(iw,$tile_width)':h=-2,tile=${grid_cols}x${grid_rows}:padding=4:margin=4:color=white" \
    -frames:v 1 -q:v 3 "$output"
}

if [[ "$mode" == "grid" && ( "$select" == "split" || "$select" == "window" ) && ${#frames[@]} -gt 1 ]]; then
  # motion frames in a top grid, average frames in a bottom grid, with a wide
  # white gap between them
  half=$(( ${#frames[@]} / 2 ))
  make_grid "$work_dir/top.png" "${frames[@]:0:$half}"
  top_desc="$half frames ($grid_rows rows by $grid_cols columns)"
  make_grid "$work_dir/bottom.png" "${frames[@]:$half}"
  bottom_desc="$(( ${#frames[@]} - half )) frames ($grid_rows rows by $grid_cols columns)"
  grid_file="$work_dir/grid.jpg"
  ffmpeg -loglevel error -i "$work_dir/top.png" -i "$work_dir/bottom.png" \
    -filter_complex "[0]pad=iw:ih+40:0:0:white[top];[1]pad=iw:ih:0:0:white[bottom];[top][bottom]vstack" \
    -frames:v 1 -q:v 3 "$grid_file"
  prefix="This image has two grids of frames from one security camera video clip, separated by a wide white gap. The top grid has $top_desc taken where something was moving. The bottom grid has $bottom_desc spread evenly across the whole clip. Within each grid the frames are in time order and separated by white lines. Consider every frame: something counts as present if it appears in any frame.$zoom_desc"
  images=("$grid_file")
elif [[ "$mode" == "grid" ]]; then
  grid_file="$work_dir/grid.jpg"
  make_grid "$grid_file" "${frames[@]}"
  prefix="This image is a grid of ${#frames[@]} frames ($grid_rows rows by $grid_cols columns, separated by white lines) taken in time order from one security camera video clip. Consider every frame: something counts as present if it appears in any frame.$zoom_desc"
  images=("$grid_file")
else
  prefix="${zoom_desc# }"
  images=("${frames[@]}")
fi

response=$("$script_path/call_ollama.bash" "$model" "${prefix:+$prefix }$question" "${images[@]}")

# A person and an animal in the same answer: ask about the animals again, told to ignore people,
# and keep each one only if the second answer confirms it. If that call fails, the first answer stands.
if [[ "$recheck_animals" == "true" ]] &&
   jq -e '.person == true and (.cat == true or .dog == true or .raccoon == true or .animal == true)' <<< "$response" > /dev/null 2>&1; then
  recheck=$("$script_path/call_ollama.bash" "$model" "${prefix:+$prefix }$recheck_question" "${images[@]}")
  if jq -e 'has("animal")' <<< "$recheck" > /dev/null 2>&1; then
    logMessage "$0 : animal recheck=<$recheck> first answer=<$response>"
    response=$(jq -c --argjson r "$recheck" '
      .cat = (.cat == true and $r.cat == true) | .dog = (.dog == true and $r.dog == true)
      | .raccoon = (.raccoon == true and $r.raccoon == true)
      | .animal = (.animal == true and ($r.animal == true or $r.cat == true or $r.dog == true or $r.raccoon == true))' <<< "$response")
  else
    logMessage "$0 : animal recheck failed, keeping the first answer"
  fi
fi

logMessage "$0 : response=<$response>"
echo "$response"
exit 0
