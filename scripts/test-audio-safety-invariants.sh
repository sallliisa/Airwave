#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
checker="$root/scripts/check-audio-safety-invariants.sh"

"$checker" "$root"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/Airwave" "$fixture/docs" "$fixture/Casks" "$fixture/Airwave.xcodeproj"
cp "$root/Airwave/Info.plist" "$fixture/Airwave/Info.plist"
cp "$root/Airwave.xcodeproj/project.pbxproj" "$fixture/Airwave.xcodeproj/project.pbxproj"
printf '%s\n' 'AudioObjectSetPropertyData(object, &address, 0, nil, size, value)' > "$fixture/Airwave/Unsafe.swift"
printf '%s\n' 'TCCAccessPreflight(service, nil)' > "$fixture/Airwave/Private.swift"
printf '%s\n' '# safe fixture' > "$fixture/README.md"

if "$checker" "$fixture" >/dev/null 2>&1; then
  echo "negative invariant fixture unexpectedly passed" >&2
  exit 1
fi

echo "audio safety invariant tests passed"
