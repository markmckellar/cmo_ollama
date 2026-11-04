#!/usr/bin/env bash
#
# Ask an ollama vision model a question about one or more images.
#
# Usage: call_ollama.bash <model> <question> <image-or-url> [<image-or-url> ...]
#
# Prints the model's answer as compact JSON on stdout. On failure prints {}
# and exits non-zero. Diagnostics go through logMessage (stderr by default).
#
# Optional settings (set in ollama_common.bash, or the environment for one run):
#   ollama_num_ctx      context window passed to the model (default 2048, the smallest
#                       ollama uses): the prompt (the images and the question: ~1500
#                       tokens for the porch's grid, ~1820 for the pet door's) plus the
#                       answer must fit
#   ollama_num_predict  max tokens the model may generate (default 256); stops
#                       runaway generations that otherwise hang until the timeout
#   ollama_timeout      seconds to wait for ollama before giving up (default 180)
#   ollama_temperature  sampling temperature (default 0, so the same images get the
#                       same answer; ollama's own default is 0.8)
#   ollama_seed         random seed (default 42)
#   ollama_fix_answer   for the person/animal answer, set legs to person and animal to
#                       true when cat, dog or raccoon is (default true)
#   ollama_stats_file   if set, a JSON line of timing/token stats is appended here
#   ollama_keep_alive   how long ollama keeps the model loaded after the call, e.g. 30m
#                       (default: ollama's own, 5 minutes). The cameras set it so the
#                       model isn't reloaded (~10 s) for every event.

script_path="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$script_path/ollama_common.bash"

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <model> <question> <image-or-url> [<image-or-url> ...]" >&2
  exit 1
fi

model=$1
prompt=$2
shift 2

# a question name such as person_animal_question or person_animal_question_v2 is
# replaced with that question from ollama_common.bash
if [[ "$prompt" =~ ^person_animal_question[a-z0-9_]*$ && -n "${!prompt}" ]]; then
  prompt="${!prompt}"
fi

num_ctx=${ollama_num_ctx:-2048}
timeout=${ollama_timeout:-180}
num_predict=${ollama_num_predict:-256}
temperature=${ollama_temperature:-0}
seed=${ollama_seed:-42}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

fail() {
  logMessage "$0 : ERROR : $1"
  echo "{}"
  exit 1
}

logMessage "$0 : START : model=<$model> num_ctx=$num_ctx images=<$*>"

# base64 encode every image into a JSON array of strings
encoded_file="$work_dir/encoded.txt"
images_file="$work_dir/images.json"
for image in "$@"; do
  local_file="$image"
  if [[ "$image" == http* ]]; then
    local_file="$work_dir/download"
    curl -sf -o "$local_file" "$image" || fail "could not download $image"
  fi
  [ -r "$local_file" ] || fail "can not read $image"
  logMessage "$0 : adding $image ($(stat -c %s "$local_file") bytes)"
  base64 --wrap=0 "$local_file" | jq -R . >> "$encoded_file"
done
jq -s . "$encoded_file" > "$images_file"

# think=false keeps thinking models (qwen3-vl) from spending time reasoning
request_file="$work_dir/request.json"
jq -n \
  --arg model "$model" \
  --arg prompt "$prompt" \
  --argjson num_ctx "$num_ctx" \
  --argjson num_predict "$num_predict" \
  --argjson temperature "$temperature" \
  --argjson seed "$seed" \
  --arg keep_alive "${ollama_keep_alive:-}" \
  --slurpfile images "$images_file" \
  '{model: $model, prompt: $prompt, stream: false, think: false, format: "json",
    options: {num_ctx: $num_ctx, num_predict: $num_predict, temperature: $temperature, seed: $seed},
    images: $images[0]} + (if $keep_alive != "" then {keep_alive: $keep_alive} else {} end)' > "$request_file"

logMessage "$0 : calling ollama at $api ($(stat -c %s "$request_file") byte request)"
output_file="$work_dir/output.json"
curl -s --max-time "$timeout" -X POST "$api/api/generate" \
  --header 'Content-Type: application/json' \
  --data "@$request_file" -o "$output_file" || fail "curl to $api failed or timed out after $timeout seconds"

if [ -d "$script_path/model_outputs" ]; then
  cp "$output_file" "$script_path/model_outputs/${model//[:\/]/_}_response.json"
fi

error=$(jq -r '.error // empty' "$output_file" 2>/dev/null)
[ -z "$error" ] || fail "ollama returned error : $error"

# Some ollama versions put qwen3-vl's answer in .thinking and leave .response
# empty, even with think=false. Strip any ```json fences and compact it.
response=$(jq -r 'if (.response // "") != "" then .response else .thinking // empty end' "$output_file" | sed -e 's/```json//g' -e 's/```//g' | jq -c . 2>/dev/null)
[ -n "$response" ] || fail "no JSON in model response : $(head -c 500 "$output_file")"

# For the person/animal answer, fix two things the models get wrong: they say
# legs for cat and dog legs (legs here means a person's legs), and they say cat
# or dog without saying animal. Other answers are left alone.
if [[ "${ollama_fix_answer:-true}" == "true" ]]; then
  response=$(jq -c 'if (has("legs") and has("person") and has("cat") and has("dog") and has("raccoon") and has("animal"))
    then .legs = (.person == true)
       | .animal = (.animal == true or .cat == true or .dog == true or .raccoon == true)
    else . end' <<< "$response")
fi

# (floor, not round: the Pi has jq 1.5, which has no round)
stats=$(jq -c --argjson num_ctx "$num_ctx" --argjson image_count "$#" --arg code "$cmo_ollama_code" '{
    code: $code, model: .model, image_count: $image_count, num_ctx: $num_ctx,
    prompt_tokens: .prompt_eval_count, output_tokens: .eval_count,
    total_seconds: ((((.total_duration // 0) / 1e8 + 0.5) | floor) / 10),
    load_seconds: ((((.load_duration // 0) / 1e8 + 0.5) | floor) / 10)}' "$output_file")
logMessage "$0 : stats=$stats response=$response"
if [ -n "$ollama_stats_file" ]; then
  echo "$stats" >> "$ollama_stats_file"
fi

prompt_tokens=$(jq -r '.prompt_eval_count // 0' "$output_file")
output_tokens=$(jq -r '.eval_count // 0' "$output_file")
if [ "$((prompt_tokens + output_tokens))" -ge "$num_ctx" ]; then
  logMessage "$0 : WARNING : prompt $prompt_tokens + output $output_tokens tokens filled the context of $num_ctx; the images or the answer were probably cut short (raise ollama_num_ctx)"
fi

echo "$response"
