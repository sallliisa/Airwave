#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
output_dir=${1:-}
python_bin=${PYTHON_BIN:-"$repo_root/.venv/bin/python"}

if [[ -z "$output_dir" ]]; then
  echo "usage: scripts/validate-ss2-presets.sh OUTPUT_DIR" >&2
  exit 2
fi
if [[ ! -d "$output_dir" ]]; then
  echo "output directory does not exist: $output_dir" >&2
  exit 1
fi
if [[ ! -x "$python_bin" ]]; then
  echo "Python environment missing: $python_bin" >&2
  echo "Install tools/ss2-to-hesuvi/requirements.lock first." >&2
  exit 1
fi

cd "$repo_root"
"$python_bin" -m pytest -q tools/ss2-to-hesuvi/tests

wav_count=$(find "$output_dir" -type f -name '*.wav' | wc -l | tr -d ' ')
manifest_count=$(find "$output_dir" -type f -name '*.wav.json' | wc -l | tr -d ' ')
if [[ "$wav_count" != "44" || "$manifest_count" != "44" ]]; then
  echo "expected 44 WAVs and 44 manifests; found $wav_count WAVs and $manifest_count manifests" >&2
  exit 1
fi

absolute_output_dir=$(cd "$output_dir" && pwd)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Airwave.xcodeproj \
  -scheme Airwave \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  AIRWAVE_HRIR_VALIDATION_DIR="$absolute_output_dir" \
  AIRWAVE_EXPECTED_HRIR_COUNT=44 \
  -only-testing:AirwaveTests/SS2PresetValidationTests \
  test

echo "Validated 44 SS2 presets with converter tests and Airwave's WAV/convolution path."
