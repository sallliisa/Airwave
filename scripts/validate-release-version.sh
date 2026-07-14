#!/bin/bash
set -euo pipefail

version=${1:-}
latest=${2:-}

fail() {
  echo "release validation failed: $*" >&2
  exit 1
}

[[ $version =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || \
  fail "version must be X.Y.Z with components from 0 through 999"

IFS=. read -r major minor patch <<< "$version"
build_number=$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))
(( build_number > 0 )) || fail "version 0.0.0 cannot be released"

if [[ -n $latest ]]; then
  latest=${latest#v}
  [[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "latest tag is not semantic: $latest"
  IFS=. read -r latest_major latest_minor latest_patch <<< "$latest"
  latest_build=$((10#$latest_major * 1000000 + 10#$latest_minor * 1000 + 10#$latest_patch))
  (( build_number > latest_build )) || fail "$version must be greater than $latest"
fi

printf 'VERSION=%s\nBUILD_NUMBER=%s\nTAG=v%s\n' "$version" "$build_number" "$version"
