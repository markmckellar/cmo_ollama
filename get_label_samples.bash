#!/usr/bin/env bash
#
# Download sample movies from the cat cam server for each label, for testing
# models against each other.
#
# Usage: get_label_samples.bash [per_label] [out_dir]
#
# For each of legs, person, cat, dog, raccoon it finds per_label events (default
# 10) whose me_ollama.json has that label true, spread over the dates on the
# server. cmo_test_data/empty.mp4 is added as a "none" clip, since the server has
# no events where every label is false. Movies go to <out_dir>/<me_name>.mp4
# (default test_movies/samples) and <out_dir>/manifest.tsv lists one line per
# movie:
#   me_name  sample_label  server_labels(json)  movie_path
# Rerunning tops up the manifest instead of starting over.
#
# Be gentle with the server. Search results include each event's whole
# me_data.json (~80KB), and a big howMayRecords makes the server build one huge
# response in memory, which has hung it. So this asks for one search result
# per request, walks back in time with "before", makes one request at a time,
# pauses between requests and backs off when the server stops answering.
#
# Optional settings (environment):
#   catcam_server   server URL (default http://173.255.215.223:9090)
#   catcam_pause    seconds to wait after every request (default 1)
#   catcam_labels   labels to fetch (default "legs person cat dog raccoon")
#   catcam_skip     a file of clips to leave out; any event whose me_name appears in
#                   it is skipped (e.g. ../cmo_test_data/labeled/labels.tsv)

script_path="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# Shared settings (and this machine's ollama_env_props.bash): where cmo_test_data is.
source "$script_path/ollama_common.bash"
server=${catcam_server:-http://173.255.215.223:9090}
pause=${catcam_pause:-1}
labels=${catcam_labels:-legs person cat dog raccoon}
skip_file=${catcam_skip:-}
group="pet_door"
per_label=${1:-10}
out_dir=${2:-test_movies/samples}

mkdir -p "$out_dir"
manifest="$out_dir/manifest.tsv"
touch "$manifest"

# get <url> [curl args...] : fetch to stdout, pause afterwards, retry with backoff
get() {
  local url=$1 wait=5 try
  shift
  for try in 1 2 3 4; do
    if curl -sf -m 60 "$@" "$url"; then
      sleep "$pause"
      return 0
    fi
    echo "request failed, waiting ${wait}s : $url" >&2
    sleep "$wait"
    wait=$((wait * 3))
  done
  echo "giving up : $url" >&2
  return 1
}

dates=($(get "$server/catcam/meeventgroup/$group?howMayRecords=1000" | jq -r '.[].meEventGroup'))
[ "${#dates[@]}" -gt 0 ] || { echo "could not list dates from $server" >&2; exit 1; }

# find_before <label> <before> : prints "<event_group> <me_name>" of the newest
# event with the label that is older than <before>, or nothing
find_before() {
  get "$server/catcam/search/$group?label=$1&howMayRecords=1&minimumDuration=0&brief=true&before=$2" |
    jq -r '.[0] // empty | "\(.me_event_group) \(.me_name)"'
}

# add_event <label> <event_group> <me_name> : download it unless already in the manifest
add_event() {
  local label=$1 event_group=$2 me_name=$3 labels movie
  grep -q "^$me_name"$'\t' "$manifest" && return 1
  [ -n "$skip_file" ] && grep -q "$me_name" "$skip_file" && return 1
  local base="$server/catcam/data/$group/$event_group/$me_name"
  labels=$(get "$base/me_ollama.json" | jq -c .) || return 1
  movie="$out_dir/$me_name.mp4"
  get "$base/me_movie.mp4" -o "$movie" || { rm -f "$movie"; return 1; }
  printf "%s\t%s\t%s\t%s\n" "$me_name" "$label" "$labels" "$movie" >> "$manifest"
  echo "$label $me_name $labels" >&2
}

for label in $labels; do
  have=$(awk -F'\t' -v l="$label" '$2 == l' "$manifest" | wc -l)
  # first aim at per_label dates spread evenly from newest to oldest, taking
  # the newest event on or before each, so the samples cover the whole range
  for (( i = 0; i < per_label && have < per_label; i++ )); do
    event=$(find_before "$label" "${dates[$(( i * ${#dates[@]} / per_label ))]}_999999")
    [ -n "$event" ] && add_event "$label" $event && have=$((have + 1))
  done
  # older dates may have no labels at all, so fill up walking back from the newest
  cursor="99999999"
  while [ "$have" -lt "$per_label" ]; do
    event=$(find_before "$label" "$cursor")
    [ -n "$event" ] || break
    cursor=${event#* }
    add_event "$label" $event && have=$((have + 1))
  done
done

empty_clip="$cmo_test_data/empty.mp4"
if [ -s "$empty_clip" ] && ! grep -q "^empty"$'\t' "$manifest"; then
  printf "%s\t%s\t%s\t%s\n" empty none '{}' "$empty_clip" >> "$manifest"
fi

echo "$(wc -l < "$manifest") movies in $manifest" >&2
