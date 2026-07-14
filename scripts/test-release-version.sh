#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
validator="$script_dir/validate-release-version.sh"

expect_success() {
  "$validator" "$1" "$2" >/dev/null
}

expect_failure() {
  if "$validator" "$1" "$2" >/dev/null 2>&1; then
    echo "expected rejection: version=$1 latest=$2" >&2
    exit 1
  fi
}

expect_success 1.2.0 v1.1.1
expect_success 2.0.0 v1.999.999
expect_failure 1.1.1 v1.1.1
expect_failure 1.1.0 v1.1.1
expect_failure v1.2.0 v1.1.1
expect_failure 1.2 v1.1.1
expect_failure 1.02.0 v1.1.1
expect_failure 1.1000.0 v1.1.1
expect_failure 0.0.0 ""

echo "release version validation tests passed"
