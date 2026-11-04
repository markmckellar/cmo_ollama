#!/usr/bin/env bash

script_path="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$script_path/ollama_common.bash"
logMessage "$0 : START" 

# we need at least 3 args
# if [ "$#" -lt "3" ]; then
#   echo "Usage: $0 <model> <question> <image1> <image2> <image3> ... <image-N>"
#   exit 1 # Exit with a non-zero status to indicate an error
# fi

#!/bin/bash

# Fetch weather and astronomy data in JSON format
WEATHER_JSON=$(curl -s "wttr.in?format=j1")

# Extract sunrise and sunset times (Format is usually "HH:MM AM/PM")
SUNRISE_STR=$(echo "$WEATHER_JSON" | jq -r '.weather[0].astronomy[0].sunrise')
SUNSET_STR=$(echo "$WEATHER_JSON" | jq -r '.weather[0].astronomy[0].sunset')

# If the API call failed or returned empty data, exit safely
if [ -z "$SUNRISE_STR" ] || [ -z "$SUNSET_STR" ]; then
    echo "Error: Could not retrieve data from wttr.in"
    exit 1
fi

# Convert sunrise and sunset times to unix timestamps for the current date
SUNRISE_TS=$(date -d "$SUNRISE_STR" +%s)
SUNSET_TS=$(date -d "$SUNSET_STR" +%s)

# Get the current system time as a unix timestamp
CURRENT_TS=$(date +%s)

#echo "CURRENT_TS=$CURRENT_TS SUNRISE_TS=$SUNRISE_TS SUNRISE_STR=$SUNRISE_STR SUNSET_TS=$SUNSET_TS SUNSET_STR=$SUNSET_STR"

# Compare timestamps to determine light or dark
if [ "$CURRENT_TS" -ge "$SUNRISE_TS" ] && [ "$CURRENT_TS" -lt "$SUNSET_TS" ]; then
    echo "light"
else
    echo "dark"
fi

