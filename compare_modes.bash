#!/usr/bin/env bash
#
# Run call_ollama_movie.bash in grid and frames mode over a set of movies and
# print one tab separated line per run:
#   movie  mode  calls  num_ctx  prompt_tokens  output_tokens  seconds  response
# (tokens and seconds are totals over the movie's Ollama calls, two when the animal recheck runs)
# frames mode needs a bigger context than the default: ollama_num_ctx=6000 compare_modes.bash ...
#
# Usage: compare_modes.bash <model> <question> <movie-file> [<movie-file> ...]

script_path="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <model> <question> <movie-file> [<movie-file> ...]" >&2
  exit 1
fi

model=$1
question=$2
shift 2

export ollama_stats_file=$(mktemp)
trap 'rm -f "$ollama_stats_file"' EXIT

printf "movie\tmode\tcalls\tnum_ctx\tprompt_tokens\toutput_tokens\tseconds\tresponse\n"
for movie in "$@"; do
  for mode in grid frames; do
    : > "$ollama_stats_file"
    response=$("$script_path/call_ollama_movie.bash" -m "$mode" "$model" "$question" "$movie")
    stats=$(jq -rs 'if length == 0 then empty else "\(length)\t\(map(.num_ctx) | max)\t\(map(.prompt_tokens // 0) | add)\t\(map(.output_tokens // 0) | add)\t\((map(.total_seconds // 0) | add) * 10 | floor / 10)" end' "$ollama_stats_file" 2>/dev/null)
    printf "%s\t%s\t%s\t%s\n" "$(basename "$movie")" "$mode" "${stats:-$'?\t?\t?\t?\t?'}" "$response"
  done
done
