#!/bin/bash

set -euo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${tests_dir}/.." && pwd)
xrayrp_ref=${XRAYRP_REF:-C:/Users/Alice/Downloads/XrayRP}
export repo_root xrayrp_ref

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    [[ "$actual" == *"$expected"* ]] || fail "${message}: missing '${expected}'"
}

assert_not_contains() {
    local actual="$1"
    local forbidden="$2"
    local message="$3"
    [[ "$actual" != *"$forbidden"* ]] || fail "${message}: found forbidden text '${forbidden}'"
}

assert_equals() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    [[ "$actual" == "$expected" ]] || fail "${message}: got '${actual}', want '${expected}'"
}

new_temp_dir() {
    mktemp -d "${TMPDIR:-/tmp}/xrayrps-test.XXXXXX"
}

remove_temp_dir() {
    local target="$1"
    [[ -n "$target" && -d "$target" && "$target" == *xrayrps-test.* ]] || fail "refusing to remove unexpected test directory"
    rm -rf -- "$target"
}
