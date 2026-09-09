#!/bin/bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/xrayrps-security.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_no_match() {
    local pattern="$1"
    shift
    if grep -nE -- "$pattern" "$@"; then
        fail "unexpected insecure pattern: ${pattern}"
    fi
}

assert_no_match '--no-check-certificate' \
    "$repo_root/install.sh" "$repo_root/install-machine.sh" "$repo_root/XrayR.sh"
assert_no_match 'bash[[:space:]]+<\(curl|curl[^|]*\|[[:space:]]*(sh|bash)' \
    "$repo_root/install.sh" "$repo_root/install-machine.sh" "$repo_root/XrayR.sh"

grep -q -- '--proto '\''=https'\''' "$repo_root/install.sh" || fail 'install.sh is missing HTTPS protocol enforcement'
grep -q -- '--proto '\''=https'\''' "$repo_root/install-machine.sh" || fail 'install-machine.sh is missing HTTPS protocol enforcement'
grep -q -- '--proto '\''=https'\''' "$repo_root/XrayR.sh" || fail 'XrayR.sh is missing HTTPS protocol enforcement'

auto_artifact="$tmp_dir/XrayR-linux-64.zip"
printf 'release artifact' > "$auto_artifact"
checksum=$(sha256sum "$auto_artifact" | awk '{print $1}')
printf '%s  XrayR-linux-64.zip\n' "$checksum" > "$tmp_dir/SHA256SUMS"

source "$repo_root/install-machine.sh"
verify_release_checksum "$tmp_dir" XrayR-linux-64.zip

printf '%064d  XrayR-linux-64.zip\n' 0 > "$tmp_dir/SHA256SUMS"
if verify_release_checksum "$tmp_dir" XrayR-linux-64.zip; then
    fail 'checksum mismatch was accepted'
fi

printf '%s  other.zip\n' "$checksum" > "$tmp_dir/SHA256SUMS"
if verify_release_checksum "$tmp_dir" XrayR-linux-64.zip; then
    fail 'missing checksum entry was accepted'
fi

if bash "$repo_root/install-machine.sh" \
    --api-host https://example.invalid --machine-id 1 --token TOKEN \
    --version '../latest' --dry-run > "$tmp_dir/version.out" 2>&1; then
    fail 'malformed release version was accepted'
fi
grep -q 'Invalid release version' "$tmp_dir/version.out" || fail 'malformed version error was not reported'

echo 'PASS: release download and checksum hardening'
