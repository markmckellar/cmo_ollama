# Settings shared by every machine that runs these scripts and both cameras (the Ollama server, the cmo_server,
# the question): the porch camera (this machine), the pet door
# Pi, and test runs. Every script sources this file, so all of them ask the same question of the same
# Ollama server and log the same way, and a git pull updates every machine. Side-by-side tests of the
# cameras therefore compare like with like.
#
# A machine that really needs something different (say, another Ollama server for a test) puts just that
# setting in ollama_env_props.bash next to this file (not tracked by git; see
# ollama_env_props.bash.template). It is sourced at the end of this file, so it overrides what is here.
# Most machines don't need one. Any setting can also be set in the environment for a single run, e.g.
#   quiet=false ollama_log_file=/dev/stderr ./call_ollama_movie.bash qwen3-vl:8b person_animal_question clip.mp4

ollama_common_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# Where ollama is running: this machine by default (the desktop with the GPU). A camera on another machine
# sets its address in its ollama_env_props.bash, e.g. api="http://<gpu-desktop>:11434".
api=${api:-"http://localhost:11434"}

# The cmo_server the cameras upload their events to, and that their Telegram links point at. Both cameras
# use this unless told otherwise, so in any one setup (production, or a test server) they always go to
# the same server: for a test, set cmo_server in that machine's ollama_env_props.bash (or the environment).
cmo_server=${cmo_server:-"https://cmoserver01.mckcode.com/"}

# The test clips and hand labels live in their own private repo, cmo_test_data (they show real people and
# places), checked out next to this one by default: ~/dev/cmo_test_data beside ~/dev/cmo_ollama.
cmo_test_data=${cmo_test_data:-"$(dirname "$ollama_common_dir")/cmo_test_data"}

# Scripts that download events from cmo_server (get_label_samples.bash) send a "reader"
# device key, so a server in google mode lets them view this account's cameras. CMO_KEY=... in a mode-600
# file, never in git (cmo_server's new_device_key.bash makes one). A camera's own key can't view, so this is
# a separate key. No file: no key (a server in open mode at home doesn't need one).
cmo_reader_key_file=${cmo_reader_key_file:-"$HOME/.config/cmo/reader_key"}

# cmo_curl_auth <url> : sets the array cmo_auth to curl's Authorization header for that server, or to nothing.
# Like the cameras, the key is sent only over https or to this machine / the home network.
cmo_curl_auth() {
    cmo_auth=()
    [ -r "$cmo_reader_key_file" ] || return 0
    local key host
    key=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?CMO_KEY[[:space:]]*=[[:space:]]*["'"'"']\?\([^"'"'"']*\)["'"'"']\?[[:space:]]*$/\2/p' "$cmo_reader_key_file" | head -1)
    [ -n "$key" ] || return 0
    host=$(printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://\[?([^]/:]+).*#\1#')
    if [[ "$1" == https://* || "$host" == localhost || "$host" =~ ^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then
        cmo_auth=(-H "Authorization: Bearer $key")
    fi
}

# This code's version, from its git tags (see release.bash): 1.3.0 on a release, 1.3.0+4 four commits
# after it, 1.3.0+4.dirty with uncommitted changes too, unknown outside a git checkout. Worked out once
# and exported, so the scripts this one starts don't run git again. It goes in every log line and in
# every stats line (so cmo_watch keeps it in each event's me_data.json) as cmo_ollama:<version>.
code_version() {
    local described
    described=$(git -C "$1" describe --tags --match 'v[0-9]*' --long --dirty 2>/dev/null) || { echo unknown; return; }
    if [[ "$described" =~ ^v([0-9.]+)-([0-9]+)-g[0-9a-f]+(-dirty)?$ ]]; then
        local version=${BASH_REMATCH[1]}
        [ "${BASH_REMATCH[2]}" != 0 ] && version+="+${BASH_REMATCH[2]}"
        [ -n "${BASH_REMATCH[3]}" ] && version+="$([ "${BASH_REMATCH[2]}" != 0 ] && echo .dirty || echo +dirty)"
        echo "$version"
    else
        echo unknown
    fi
}
export cmo_ollama_version=${cmo_ollama_version:-$(code_version "$ollama_common_dir")}
cmo_ollama_code="cmo_ollama:$cmo_ollama_version"

ollama_log_tag="OLLAMA_LOG $cmo_ollama_code"
quiet=${quiet:-true}

# The original question. It says the objects were "detected", which pushes the
# model toward answering yes.
person_animal_question_v1="Given the following objects detected in an image: ['legs','person', 'cat', 'dog', 'raccoon','animal'].  Is there a persons legs?  Is there a person? Is there a cat? Is there a dog? Is there a raccoon? Is there a animal? Respond in JSON format with the following keys: 'legs', 'person', 'cat', 'dog', 'raccoon', 'animal' and their corresponding boolean values (true or false)."
# Neutral rewrite of person_animal_question: it doesn't say the objects were
# detected, says what each key means, and says not to guess.
person_animal_question_v2="Look carefully at what is actually visible. Answer only from what you can clearly see and do not guess. legs: true if a human's legs or feet are visible; animal legs do not count. person: true if a human or any part of a human is visible. cat: true if a cat is visible. dog: true if a dog is visible. raccoon: true if a raccoon is visible (grey fur, black mask around the eyes, ringed tail). animal: true if a cat, dog, raccoon or any other mammal is visible; insects and spiders do not count. Respond in JSON with exactly these keys and true or false values: legs, person, cat, dog, raccoon, animal."
# v2 plus a delivery key, for the porch camera. Being tested; nothing uses it by default yet.
person_animal_question_v3="Look carefully at what is actually visible. Answer only from what you can clearly see and do not guess. legs: true if a human's legs or feet are visible; animal legs do not count. person: true if a human or any part of a human is visible. cat: true if a cat is visible. dog: true if a dog is visible. raccoon: true if a raccoon is visible (grey fur, black mask around the eyes, ringed tail). animal: true if a cat, dog, raccoon or any other mammal is visible; insects and spiders do not count. delivery: true if a person walked up to the door holding envelopes or packages and it appears they then left without them. Respond in JSON with exactly these keys and true or false values: legs, person, cat, dog, raccoon, animal, delivery."
# The question scripts get when they ask for person_animal_question. Both cameras use this one.
person_animal_question="$person_animal_question_v2"

# cute_ollama.bash's question: a short, cute sentence about the picture, to be said on the Google Home
# speakers (their messages are at most 200 characters), as JSON {"text": "..."}.
# The original question: it said little about the scene, so it sometimes made things up ("the cat is
# looking at the doorbell", with no doorbell).
cute_question_v1="This photo is from a camera at the door of a house. In one short, cute, playful sentence of at most 20 words, say who is there and what they are doing, as a friendly house would announce it out loud. Describe only what you can clearly see; do not guess names or invent things that are not visible. If nobody is there, say so in a cute way. Respond in JSON with exactly one key, text, whose value is the sentence."
# The pet door camera's question (2026-11-19): says it is a pet door on a porch and what was seen
# ({label}: cute_ollama.bash fills in what the camera found, e.g. cat or raccoon), and keeps the
# sentence to that animal and the pet door.
cute_question_v2="This photo is from a camera watching a pet door on the porch of a house. A {label} has just been seen there, most likely coming in through the pet door, going out through it, or waiting by it. In one short, cute, playful sentence of at most 20 words, say what the {label} seems to be doing, as a friendly house would announce it out loud. Make it fun: you may mention the {label}'s pose or mood, but not its colour (night pictures change colours). Talk only about the {label} and the pet door; do not mention any other objects. Describe only what you can clearly see; do not guess names or invent things that are not visible. If you cannot tell whether it is coming in or going out, say it is waiting, in a playful way. Respond in JSON with exactly one key, text, whose value is the sentence."
cute_question="$cute_question_v2"

# Log messages go here when quiet=false (the cameras turn logging on for their calls). ~/logs is
# where the cameras keep their logs too; CMO_LOG_DIR moves all of them. Set ollama_log_file=/dev/stderr
# to see the messages while running a script by hand.
ollama_log_file=${ollama_log_file:-${CMO_LOG_DIR:-$HOME/logs}/call_ollama.log}

logMessage() {
    if [[ "$quiet" == "false" ]]; then
        if [[ "$ollama_log_file" != /dev/* ]]; then
            mkdir -p "$(dirname "$ollama_log_file")"
            # roll over at 5 MB (keeping one old file, .1), like the cameras' logs
            if [ "$(stat -c %s "$ollama_log_file" 2>/dev/null || echo 0)" -gt 5242880 ]; then
                mv -f "$ollama_log_file" "$ollama_log_file.1"
            fi
        fi
        echo "$(date +%FT%T) : $ollama_log_tag : $1" >> "$ollama_log_file"
    fi
}

# Optional tuning, with the defaults the scripts use. Set any of them here to change them everywhere.
# ollama_num_ctx=2048            # context window sent with each request (prompt + answer must fit)
# ollama_timeout=180             # seconds to wait for ollama
# ollama_num_predict=256         # max tokens generated; stops runaway answers
# ollama_movie_mode=grid         # grid (all frames tiled in one image) or frames (one image per frame)
# ollama_movie_frames=4          # frames sampled from each movie
# ollama_grid_max_width=1024     # max pixel width of the grid image
# ollama_frame_select=split      # motion, average, mixed, split or thumbnail (split = 2x2 movement grid over 2x2 average grid)
# ollama_recheck_animals=true    # person + animal in one answer: ask about the animals again, people ignored
# ollama_keep_alive=30m          # how long ollama keeps the model loaded (the cameras set this)

# this machine's own differences, if it has any
if [ -f "$ollama_common_dir/ollama_env_props.bash" ]; then
    source "$ollama_common_dir/ollama_env_props.bash"
fi

logMessage "START of ollama env"
