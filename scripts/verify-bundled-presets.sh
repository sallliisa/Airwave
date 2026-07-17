#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app=${1:-}

if [[ -z "$app" ]]; then
  echo "usage: $0 /path/to/Airwave.app" >&2
  exit 2
fi

resources="$app/Contents/Resources/assets"
[[ -d "$resources" ]] || { echo "bundled assets directory missing: $resources" >&2; exit 1; }

declare -a files=(
  "eq/Bass Booster.txt"
  "eq/Bass Reducer.txt"
  "eq/Treble Booster.txt"
  "eq/Treble Reducer.txt"
  "eq/Vocal Booster.txt"
  "hrtf/NeutralSH1.0.wav"
  "hrtf/RoomSH1.0.wav"
  "hrtf/StageSH1.0.wav"
)

for relative in "${files[@]}"; do
  source="$root/assets/$relative"
  bundled="$resources/$relative"
  [[ -f "$bundled" ]] || { echo "missing bundled preset: $relative" >&2; exit 1; }
  source_hash=$(shasum -a 256 "$source" | awk '{print $1}')
  bundled_hash=$(shasum -a 256 "$bundled" | awk '{print $1}')
  [[ "$source_hash" == "$bundled_hash" ]] || {
    echo "bundled preset hash mismatch: $relative" >&2
    exit 1
  }
done

actual_count=$(find "$resources" -type f \( -name '*.txt' -o -name '*.wav' \) | wc -l | tr -d ' ')
[[ "$actual_count" == "8" ]] || { echo "expected 8 bundled preset files, found $actual_count" >&2; exit 1; }

echo "bundled presets verified in $app"
