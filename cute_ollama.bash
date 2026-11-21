#!/usr/bin/env bash
#
# Ask an ollama vision model for a short, cute sentence about a photo, to be said out loud (the
# Google Home announcements).
#
# Usage: cute_ollama.bash <model> <image-or-url> [<question> [<label> [<context>]]]
#
# Prints {"text": "..."} on stdout, or {} and exits non-zero on failure (as call_ollama.bash does).
# The photo is shrunk to at most cute_width pixels wide first, so it fits the 2048 token context.
# The question defaults to cute_question in ollama_common.bash (also when given as ""). Every {label}
# in it becomes <label>: what the camera found, e.g. cat, raccoon or "cat and raccoon" (default animal).
# {context} becomes <context>: facts about right now, e.g. "it is evening on a Thursday; it is dark
# outside" (default "nothing special"). {style} becomes one of cute_styles at random (or cute_style).
#
# Optional settings (ollama_common.bash, or the environment for one run), besides call_ollama.bash's:
#   cute_width          widest photo sent, in pixels (default 640: about 1200 prompt tokens)
#   cute_style          use this {style} instead of a random one of cute_styles
#   ollama_temperature  default 0.7 here, so the same cat isn't always described the same way
#   ollama_seed         default a new random one each run, for the same reason

script_path="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$script_path/ollama_common.bash"

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <model> <image-or-url> [<question> [<label> [<context>]]]" >&2
  exit 1
fi

model=$1
image=$2
question=${3:-$cute_question}
label=${4:-animal}
context=${5:-nothing special}
style=${cute_style:-${cute_styles[RANDOM % ${#cute_styles[@]}]}}
question=${question//\{label\}/$label}
question=${question//\{context\}/$context}
question=${question//\{style\}/$style}
logMessage "$0 : style: $style; context: $context"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

fail() {
  logMessage "$0 : ERROR : $1"
  echo "{}"
  exit 1
}

if [[ "$image" == http* ]]; then
  curl -sf -o "$work_dir/download" "$image" || fail "could not download $image"
  image="$work_dir/download"
fi
[ -r "$image" ] || fail "can not read $image"

small="$work_dir/small.jpg"
ffmpeg -loglevel error -y -i "$image" -vf "scale='min(${cute_width:-640},iw)':-2" -frames:v 1 -q:v 3 "$small" \
  || fail "ffmpeg could not read $image"

response=$(ollama_temperature=${ollama_temperature:-0.7} ollama_seed=${ollama_seed:-$RANDOM} \
  "$script_path/call_ollama.bash" "$model" "$question" "$small") || fail "call_ollama.bash failed"
jq -e '.text | type == "string" and length > 0' <<< "$response" > /dev/null \
  || fail "no text in the answer : $response"
jq -c '{text: .text}' <<< "$response"
