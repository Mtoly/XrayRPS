#!/bin/bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_equals() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    [[ "$actual" == "$expected" ]] || fail "${message}: got '${actual}', want '${expected}'"
}
assert_contains() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    [[ "$actual" == *"$expected"* ]] || fail "${message}: missing '${expected}'"
}

test_download_urls() {
    local version_tag="$1"
    local test_dir
    local destination
    local calls
    test_dir=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-version-test.XXXXXX")
    destination="$test_dir/archive.zip"
    calls="$test_dir/calls"
    download_https() {
        printf '%s\n' "$1" >> "$calls"
        printf archive > "$2"
    }
    verify_release_checksum() { return 0; }
    download_release_artifact "$version_tag" XrayR-linux-64.zip "$destination"
    calls=$(<"$calls")
    assert_contains "$calls" "/releases/download/0.9.4/XrayR-linux-64.zip" 'archive URL did not use the normalized tag'
    assert_contains "$calls" "/releases/download/0.9.4/SHA256SUMS" 'checksum URL did not use the normalized tag'
    [[ -f "$destination" ]] || fail 'normalized release archive was not staged'
    rm -rf -- "$test_dir"
}

XRAYR_TEST_MODE=1 source "$repo_root/install.sh"
assert_equals "$(normalize_release_version '0.9.4')" '0.9.4' 'standard installer did not preserve an unprefixed release tag'
assert_equals "$(normalize_release_version 'v0.9.4')" '0.9.4' 'standard installer did not remove an optional v prefix'
if normalize_release_version '../latest' >/dev/null 2>&1; then
    fail 'standard installer accepted a malformed release version'
fi
if normalize_release_version 'vv0.9.4' >/dev/null 2>&1; then
    fail 'standard installer accepted a double v prefix'
fi
test_download_urls "$(normalize_release_version '0.9.4')"

XRAYR_TEST_MODE=1 source "$repo_root/install-machine.sh"
api_host=https://panel.example.com
machine_id=7
token=machine-token
panel_type=NewV2board
timeout=30
discovery_interval=60
heartbeat_interval=30
reconnect_backoff=5
resync_on_reconnect=true
listen_ip=127.0.0.1
send_ip=127.0.0.1
version=0.9.4
validate_args
assert_equals "$version" '0.9.4' 'machine installer did not preserve an unprefixed release tag'

version=v0.9.4
validate_args
assert_equals "$version" '0.9.4' 'machine installer did not remove an optional v prefix'

version=latest
validate_args
assert_equals "$version" 'latest' 'machine installer changed latest resolution'

version=../latest
if (validate_args >/dev/null 2>&1); then
    fail 'machine installer accepted a malformed release version'
fi
invalid_output=$(version=../latest; (validate_args) 2>&1 || true)
assert_contains "$invalid_output" 'Invalid release version: ../latest' 'machine installer lost the invalid version in its error'

version=vv0.9.4
if (validate_args >/dev/null 2>&1); then
    fail 'machine installer accepted a double v prefix'
fi
test_download_urls "$(normalize_release_version 'v0.9.4')"

echo 'PASS: explicit XrayRP release tags normalize without a v prefix'
