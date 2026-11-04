#!/usr/bin/env bash
#
# Run several models over the movies in a manifest (from get_label_samples.bash)
# with the person/animal question, saving one JSON line per movie and model.
# Set ollama_question to another question name (e.g. person_animal_question_v2)
# to try a different prompt.
#
# Usage: model_agreement.bash <manifest.tsv> <results.jsonl> <model> [<model> ...]
#
# Each line of results.jsonl looks like:
#   {"model":..., "me_name":..., "sample_label":..., "server":{...},
#    "answer":{...}, "seconds":..., "calls":..., "num_ctx":...,
#    "prompt_tokens":..., "output_tokens":...}
# seconds and the token counts are totals over the clip's Ollama calls (two when
# the animal recheck runs); num_ctx is the context window they were sent with.
# Runs that already have a line in results.jsonl are skipped, so an
# interrupted run can be restarted. Models run one after another so only one
# is loaded at a time. Summarise with model_agreement_report.py.

script_path="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <manifest.tsv> <results.jsonl> <model> [<model> ...]" >&2
  exit 1
fi

manifest=$1
results=$2
question=${ollama_question:-person_animal_question}
shift 2
touch "$results"

export ollama_stats_file=$(mktemp)
trap 'rm -f "$ollama_stats_file"' EXIT

for model in "$@"; do
  while IFS=$'\t' read -r me_name sample_label server_labels movie; do
    if jq -e --arg m "$model" --arg n "$me_name" 'select(.model == $m and .me_name == $n)' "$results" > /dev/null 2>&1; then
      continue
    fi
    : > "$ollama_stats_file"
    answer=$("$script_path/call_ollama_movie.bash" "$model" "$question" "$movie" < /dev/null)
    stats=$(jq -sc 'if length == 0 then {} else {seconds: ((map(.total_seconds // 0) | add) * 10 | floor / 10),
        calls: length, num_ctx: (map(.num_ctx // 0) | max), prompt_tokens: (map(.prompt_tokens // 0) | add),
        output_tokens: (map(.output_tokens // 0) | add)} end' "$ollama_stats_file" 2>/dev/null)
    jq -nc --arg model "$model" --arg me_name "$me_name" --arg sample_label "$sample_label" \
      --argjson server "$server_labels" --arg answer "$answer" --argjson stats "${stats:-{\}}" \
      '{model: $model, me_name: $me_name, sample_label: $sample_label, server: $server,
        answer: ($answer | fromjson? // {}), seconds: ($stats.seconds // null)}
       + ($stats | del(.seconds))' >> "$results"
    echo "$model $sample_label $me_name $answer" >&2
  done < "$manifest"
done
