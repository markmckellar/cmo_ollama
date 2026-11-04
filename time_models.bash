#!/usr/bin/bash

# the Ollama server and the other settings are in ollama_common.bash
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/ollama_common.bash"

if [ "$#" -lt "2" ]; then
  echo "Usage: $0 <question> <image or image-url>"
  exit 1 # Exit with a non-zero status to indicate an error
fi

prompt=$1
file=$2

for model in $(curl -s "$api/api/tags" | jq -r '.models[].model' | egrep -v 'llama3.2:1b'); do
  echo "Processing: $model"
  ./call_ollama.bash "$model" "$prompt" "$file"
  curl -s "$api/api/generate" -d  `jo model=$model keep_alive=0` | grep -v "done..true"

  echo "Done with: $model"
  echo ""
  echo ""
done