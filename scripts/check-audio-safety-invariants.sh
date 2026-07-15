#!/bin/bash
set -euo pipefail

root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
fail() { echo "audio safety invariant failed: $*" >&2; exit 1; }

source_root="$root/Airwave"
forbidden_source='AudioObjectSetPropertyData|AudioHardwareServiceSetPropertyData|AudioDeviceSetProperty|kAudioDevicePropertyVolume|kAudioDevicePropertyMute|kAudioHardwareServiceDeviceProperty_VirtualMasterVolume|NSMicrophoneUsageDescription'
if grep -REn "$forbidden_source" "$source_root" --include='*.swift' --include='*.plist'; then
  fail "production source contains route/volume mutation API or microphone metadata"
fi

if grep -REni 'install (BlackHole|a virtual audio)|requires (BlackHole|a virtual audio)|create (an )?aggregate device|manual aggregate device setup' \
  "$root/README.md" "$root/docs" "$root/Casks" --include='*.md' --include='*.rb'; then
  fail "shipping guidance still instructs legacy virtual/aggregate routing"
fi

grep -q '<key>NSAudioCaptureUsageDescription</key>' "$source_root/Info.plist" || \
  fail "NSAudioCaptureUsageDescription missing"
grep -q 'MACOSX_DEPLOYMENT_TARGET = 15.0;' "$root/Airwave.xcodeproj/project.pbxproj" || \
  fail "macOS 15 deployment target missing"

echo "audio safety invariants passed"
