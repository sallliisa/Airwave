#!/bin/bash
set -euo pipefail

archive=${1:?Pass the release ZIP}
version=${2:?Pass the release version}
build_number=${3:?Pass the release build number}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/airwave-release-au.XXXXXXXX")
scratch=$(cd "$scratch" && pwd -P)
app="$scratch/Airwave.app"
extension="$app/Contents/PlugIns/AirwaveSpatialAU.appex"
bundle_id=com.southneuhof.Airwave.Spatial
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

cleanup() {
    if [[ -d "$extension" ]]; then
        pluginkit -r "$extension" || true
        "$lsregister" -u "$app" || true
    fi
    rm -R "$scratch"
}
trap cleanup EXIT

ditto -x -k "$archive" "$scratch"
plist="$extension/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")" = "$bundle_id"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")" = "$build_number"
codesign --verify --deep --strict --verbose=2 "$app"
architectures=$(lipo -archs "$extension/Contents/MacOS/AirwaveSpatialAU")
for architecture in arm64 x86_64; do
    [[ " $architectures " == *" $architecture "* ]] || {
        echo "Airwave Spatial is missing $architecture. Found $architectures." >&2
        exit 1
    }
done

"$lsregister" -f "$app"
pluginkit -a "$extension"
for attempt in {1..10}; do
    registered=$(pluginkit -m -vv -i "$bundle_id" | sed -n 's/^[[:space:]]*Path = //p') || registered=
    components=$(auval -a)
    if [[ "$registered" = "$extension" ]] && \
        grep -Eq '^aufx[[:space:]]+Awsp[[:space:]]+Awve[[:space:]]' <<< "$components"; then
        break
    fi
    if [[ "$attempt" = 10 ]]; then
        echo "Could not discover the Audio Unit from $extension. Registered path: $registered" >&2
        exit 1
    fi
    sleep 1
done

log="$scratch/auval.log"
if ! auval -v aufx Awsp Awve > "$log" 2>&1; then
    cat "$log" >&2
    exit 1
fi
cat "$log"
grep -Fq 'AU VALIDATION SUCCEEDED' "$log"
