#!/usr/bin/env bash
# Trim a raw screen recording of `typebud --demo` to the tour, mux in the typing-sound
# track the app wrote, and encode a shareable H.264 MP4 (≤ 1920 wide, 30 fps, < ~20 MB).
#
# usage: scripts/demo-encode.sh <rec dir> <out.mp4>
#   <rec dir>/raw.mkv or raw.mov   the recording
#   <rec dir>/start_unix           wall clock (s) when the recording started
#   zig-out/demo/timeline.json     start_unix + duration of the tour
#   zig-out/demo/audio.wav         the typing sounds, sample 0 = tour t = 0
set -euo pipefail
rec=$1
out=$2
raw=$(ls "$rec"/raw.mkv "$rec"/raw.mov 2>/dev/null | head -1 || true)
[ -n "$raw" ] || { echo "no recording in $rec"; exit 1; }
py=$(command -v python3 || command -v python)
read -r offset duration < <("$py" - "$rec/start_unix" zig-out/demo/timeline.json <<'PY'
import json, sys
rec_start = float(open(sys.argv[1]).read().strip())
t = json.load(open(sys.argv[2]))
print(f"{max(0.0, t['start_unix'] - rec_start):.3f} {t['duration'] + 0.5:.3f}")
PY
)
echo "recording: $raw  tour starts at +${offset}s, lasts ${duration}s"
encode() {
  local crf=$1
  local audio=(-an)
  if [ -s zig-out/demo/audio.wav ]; then
    audio=(-i zig-out/demo/audio.wav -map 0:v:0 -map 1:a:0 -c:a aac -b:a 128k)
  fi
  ffmpeg -hide_banner -loglevel warning -y -ss "$offset" -t "$duration" -i "$raw" "${audio[@]}" \
    -vf "fps=30,scale='min(1920,iw)':-2:flags=lanczos,format=yuv420p" \
    -c:v libx264 -preset slow -crf "$crf" -movflags +faststart -shortest "$out"
}
encode 23
size=$(wc -c < "$out")
if [ "$size" -gt 20000000 ]; then
  echo "$out is $size bytes; re-encoding smaller"
  encode 29
fi
ls -la "$out"
