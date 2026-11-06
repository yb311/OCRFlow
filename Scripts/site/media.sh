#!/bin/bash
# Cuts the website's videos and stills from the film's masters:
#   Scripts/site/media.sh <folder with film-{en,zh}.mp4 and clean-{en,zh}.mp4>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ffmpeg="$here/../film/node_modules/ffmpeg-static/ffmpeg"
masters="$1"
media="$here/../../site/media"
mkdir -p "$media"
run() { "$ffmpeg" -hide_banner -loglevel error -y "$@"; }

# name, master, from, to: a silent 720p loop that fades in and out, and its first
# bright frame as the poster.
loop() {
  local length; length=$(python3 -c "print($4-$3)")
  local out; out=$(python3 -c "print($length-0.5)")
  run -ss "$3" -t "$length" -i "$2" \
    -vf "fps=30,scale=1280:720:flags=lanczos,fade=in:st=0:d=0.5,fade=out:st=$out:d=0.5" \
    -c:v libx264 -preset slow -crf 25 -maxrate 3M -bufsize 6M -pix_fmt yuv420p -movflags +faststart -an "$media/$1.mp4"
  run -ss "$(python3 -c "print($length*0.5)")" -i "$media/$1.mp4" -frames:v 1 -q:v 4 "$media/$1.jpg"
}

for lang in en zh; do
  run -i "$masters/film-$lang.mp4" \
    -vf "scale=1920:1080" -c:v libx264 -preset slow -crf 24 -maxrate 6M -bufsize 12M -pix_fmt yuv420p \
    -c:a aac -b:a 160k -movflags +faststart "$media/film-$lang.mp4"
  run -ss 46.6 -i "$masters/film-$lang.mp4" -frames:v 1 -vf "scale=1920:1080" -q:v 3 "$media/poster-$lang.jpg"
  loop "capture-$lang" "$masters/clean-$lang.mp4" 16.6 21.8
  loop "ribbon-$lang" "$masters/clean-$lang.mp4" 22.6 27.6
  loop "deck-$lang" "$masters/clean-$lang.mp4" 28.0 35.9
done
loop hero "$masters/clean-en.mp4" 1.0 6.8
run -ss 46.6 -i "$masters/film-en.mp4" -frames:v 1 -vf "crop=1920:1008,scale=1200:630" -q:v 3 "$media/share.jpg"
ls -la "$media"
du -sh "$media"
