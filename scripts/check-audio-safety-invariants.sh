#!/bin/bash
set -euo pipefail

root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
fail() { echo "audio safety invariant failed: $*" >&2; exit 1; }

source_root="$root/Airwave"
forbidden_source='AudioObjectSetPropertyData|AudioHardwareServiceSetPropertyData|AudioDeviceSetProperty|kAudioDevicePropertyVolume|kAudioDevicePropertyMute|kAudioHardwareServiceDeviceProperty_VirtualMasterVolume|NSMicrophoneUsageDescription|TCC\.framework|TCCAccessPreflight|TCCAccessRequest|kTCCServiceAudioCapture|dlopen|dlsym'
if grep -REn "$forbidden_source" "$source_root" --include='*.swift' --include='*.plist'; then
  fail "production source contains forbidden private TCC, route/volume mutation API, or microphone metadata"
fi

if grep -REni 'install (BlackHole|a virtual audio)|requires (BlackHole|a virtual audio)|create (an )?aggregate device|manual aggregate device setup' \
  "$root/README.md" "$root/docs" "$root/Casks" --include='*.md' --include='*.rb'; then
  fail "shipping guidance still instructs legacy virtual/aggregate routing"
fi

grep -q '<key>NSAudioCaptureUsageDescription</key>' "$source_root/Info.plist" || \
  fail "NSAudioCaptureUsageDescription missing"
grep -q 'MACOSX_DEPLOYMENT_TARGET = 15.0;' "$root/Airwave.xcodeproj/project.pbxproj" || \
  fail "macOS 15 deployment target missing"

callback_source="$source_root/ParametricEqualizerProcessor.swift"
callback_body=$(awk '
  /BEGIN REALTIME CALLBACK/ { inside=1; next }
  /END REALTIME CALLBACK/ { inside=0; next }
  inside { print }
' "$callback_source")
if grep -Eni 'Array|append|reserveCapacity|DispatchQueue|Task[[:space:]]*\{|withLock\(|print\(|Logger|FileManager|UserDefaults|AudioObject|AudioDevice|AudioHardware' <<< "$callback_body"; then
  fail "equalizer realtime callback contains allocation, waiting, logging, filesystem, or Core Audio work"
fi

graph_callback_source="$source_root/AudioEffectGraph.swift"
graph_callback_body=$(awk '
  /BEGIN REALTIME CALLBACK/ { inside=1; next }
  /END REALTIME CALLBACK/ { inside=0; next }
  inside { print }
' "$graph_callback_source")
if grep -Eni 'Array|append|reserveCapacity|DispatchQueue|Task[[:space:]]*\{|withLock\(|print\(|Logger|FileManager|UserDefaults|AudioObject|AudioDevice|AudioHardware' <<< "$graph_callback_body"; then
  fail "audio effect graph realtime callback contains allocation, waiting, logging, filesystem, or Core Audio work"
fi

echo "audio safety invariants passed"
