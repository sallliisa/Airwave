#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
project="$root/Airwave.xcodeproj/project.pbxproj"
cask="$root/Casks/airwave.rb"

test "$(grep -c 'MARKETING_VERSION = 2.0.0;' "$project")" -eq 2
test "$(grep -c 'CURRENT_PROJECT_VERSION = 2000000;' "$project")" -eq 2
test "$(grep -c 'MACOSX_DEPLOYMENT_TARGET = 15.0;' "$project")" -ge 1
grep -q 'version "2.0.0"' "$cask"
grep -q 'sha256 "REPLACE_WITH_2_0_0_SHA256"' "$cask"
grep -q 'depends_on macos: :sequoia' "$cask"
grep -q '<key>LSMinimumSystemVersion</key><string>$(MACOSX_DEPLOYMENT_TARGET)</string>' "$root/Airwave/Info.plist"

echo "Airwave 2.0 metadata verified (Cask checksum intentionally pending artifact)"
