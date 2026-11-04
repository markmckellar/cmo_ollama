#!/usr/bin/bash

# if [ "$#" -lt "3" ]; then
#   echo "Usage: $0 <model> <question> <image>"
#   exit 1 # Exit with a non-zero status to indicate an error
# fi

model=$1
prompt=$2
file=$3
stream="false"
api="http://173.255.215.223:9090"

# json_data=`curl -s --location "$api/catcam/megroups" --header 'Content-Type: application/json'`
# echo $json_data
# meGroupList=$(echo "$json_data" | jq -r '.[].meGroup')
# meGroupList=$(curl -s --location "$api/catcam/megroups" --header 'Content-Type: application/json')
meGroupList=($(curl -s --location "$api/catcam/megroups" --header 'Content-Type: application/json'| jq -r '.[].meGroup'))



for meGroup in "${meGroupList[@]}"; do
  echo "Current element : $meGroup"
  meEventGroupList=($(curl -s --location "$api/catcam/meeventgroup/${meGroup}?howMayRecords=2000" --header 'Content-Type: application/json'| jq -r '.[].meEventGroup'))

  for meEventGroup in "${meEventGroupList[@]}"; do
    echo "  Current element : meGroup=$meGroup meEventGroup=$meEventGroup"
    meEventList=($(curl -s --location "$api/catcam/meeventgroup/$meGroup/$meEventGroup?howMayRecords=2000&startRecord=0&minimumDuration=6" --header 'Content-Type: application/json' | jq -r '.[].me_name'))

  for meEvent in "${meEventList[@]}"; do
      echo "     Current element : meGroup=$meGroup meEventGroup=$meEventGroup meEvent=$meEvent"
      
      me_rep_image_url="http://173.255.215.223:9090/catcam/data/$meGroup/$meEventGroup/$meEvent/me_rep_image.jpg"
      echo "          me_rep_image_url=$me_rep_image_url"
      # ./call_ollama.bash "qwen2.5vl:7b" "What animal is in this picture?" "$me_rep_image_url"
      test_image="test_images/rep_images/$meEvent.jpg"
      if [ ! -f "$test_image" ]; then
        echo "       $test_image does not exist."
        curl -s -o "$test_image" --location "$me_rep_image_url"
      fi
      
      me_movie_url="http://173.255.215.223:9090/catcam/data/$meGroup/$meEventGroup/$meEvent/me_movie.mp4"
      echo "          me_movie_url=$me_movie_url"
      test_movie="test_movies/$meEvent.mp4"
      if [ ! -f "$test_movie" ]; then
        echo "       $test_movie does not exist."
        curl -s -o "$test_movie" --location "$me_movie_url"
      fi

  done

  done


done
