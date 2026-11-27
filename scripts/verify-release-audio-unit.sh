#!/bin/bash
set -euo pipefail

archive=${1:?Pass the release ZIP}
version=${2:?Pass the release version}
build_number=${3:?Pass the release build number}
mode=${4:-}
if [[ -n "$mode" && "$mode" != --package-only ]]; then
    echo "Unknown mode: $mode" >&2
    exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/airwave-release-au.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
app="$scratch/Airwave.app"
plugins="$app/Contents/PlugIns"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
    if [[ "$mode" != --package-only && -d "$app" ]]; then
        for extension in "$plugins"/*.appex; do
            if [[ -d "$extension" ]]; then pluginkit -r "$extension" || true; fi
        done
        "$lsregister" -u "$app" || true
    fi
    rm -R "$scratch"
}
trap cleanup EXIT

read_plist() {
    /usr/libexec/PlistBuddy -c "Print $2" "$1"
}

verify_architectures() {
    local binary=$1 architectures architecture
    architectures=$(lipo -archs "$binary")
    for architecture in arm64 x86_64; do
        if [[ " $architectures " != *" $architecture "* ]]; then
            echo "$binary is missing $architecture. Found $architectures." >&2
            return 1
        fi
    done
}

verify_unit() {
    local name=$1 bundle_id=$2 subtype=$3 manufacturer=$4
    local extension="$plugins/$name.appex" plist component prefix registered components log attempt
    plist="$extension/Contents/Info.plist"
    component=NSExtension:NSExtensionAttributes:AudioComponents:0
    test "$(read_plist "$plist" CFBundleIdentifier)" = "$bundle_id"
    test "$(read_plist "$plist" CFBundleShortVersionString)" = "$version"
    test "$(read_plist "$plist" CFBundleVersion)" = "$build_number"
    test "$(read_plist "$plist" "$component:type")" = aufx
    test "$(read_plist "$plist" "$component:subtype")" = "$subtype"
    test "$(read_plist "$plist" "$component:manufacturer")" = "$manufacturer"
    verify_architectures "$extension/Contents/MacOS/$name"
    if [[ "$mode" == --package-only ]]; then return; fi

    pluginkit -a "$extension"
    prefix="^aufx[[:space:]]+$subtype[[:space:]]+$manufacturer[[:space:]]"
    for attempt in {1..10}; do
        registered=$(pluginkit -m -vv -i "$bundle_id" | sed -n 's/^[[:space:]]*Path = //p') || registered=
        components=$(auval -a)
        if [[ "$registered" = "$extension" ]] && grep -Eq "$prefix" <<< "$components"; then break; fi
        if [[ "$attempt" = 10 ]]; then
            echo "Could not discover $name from $extension. Registered path: $registered" >&2
            return 1
        fi
        sleep 1
    done

    log="$scratch/$name.log"
    if ! auval -v aufx "$subtype" "$manufacturer" > "$log" 2>&1; then
        cat "$log" >&2
        return 1
    fi
    cat "$log"
    grep -Fq 'AU VALIDATION SUCCEEDED' "$log"
}

ditto -x -k "$archive" "$scratch"
test "$(read_plist "$app/Contents/Info.plist" CFBundleIdentifier)" = com.southneuhof.Airwave
test "$(read_plist "$app/Contents/Info.plist" CFBundleShortVersionString)" = "$version"
test "$(read_plist "$app/Contents/Info.plist" CFBundleVersion)" = "$build_number"
test "$(read_plist "$app/Contents/Info.plist" LSMinimumSystemVersion)" = 15.0
codesign --verify --deep --strict --verbose=2 "$app"
verify_architectures "$app/Contents/MacOS/Airwave"

if [[ "$mode" != --package-only ]]; then
    "$lsregister" -f "$app"
fi
verify_unit AirwaveSpatialAU com.southneuhof.Airwave.Spatial Awsp Awve

if (( ${version%%.*} >= 3 )); then
    verify_unit AirwaveEqualizerAU com.southneuhof.Airwave.Equalizer EqAP Snhf
    for preset in Neutral Room Stage; do
        wav="${preset}SH1.0.wav"
        cmp "$root/assets/hrtf/$wav" "$plugins/AirwaveSpatialAU.appex/Contents/Resources/$wav"
    done
    for file in "$root"/assets/eq/*.txt; do
        cmp "$file" "$plugins/AirwaveEqualizerAU.appex/Contents/Resources/${file##*/}"
    done
fi
echo "release audio units verified for Airwave $version"
