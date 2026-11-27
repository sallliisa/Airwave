#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
work=$(mktemp -d "${TMPDIR:-/tmp}/airwave-spatial.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
cp assets/hrtf/NeutralSH1.0.wav "$work/"
xcrun swiftc -O -whole-module-optimization -module-cache-path "$work/modules" \
    Airwave/{ConvolutionEngine,FFTSetupManager,HRIRRenderPlan,InputLayoutResolution,Logger,Resampler,VirtualSpeaker,WAVLoader}.swift \
    AirwaveSpatialAU/{AirwaveSpatialAudioUnit,SpatialProcessor,SpatialRenderResources}.swift \
    scripts/verify-spatial-render.swift -o "$work/verify"
"$work/verify" "$work/NeutralSH1.0.wav" "$@"
