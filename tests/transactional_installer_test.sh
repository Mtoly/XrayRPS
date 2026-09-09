#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail(){ echo "FAIL: $*" >&2; exit 1; }
if grep -qF "rm /usr/local/XrayR/ -rf" "$repo_root/install.sh"; then fail "legacy installer still removes the live tree before staging"; fi
grep -qF "staged_install=" "$repo_root/install.sh" || fail "legacy staging directory missing"
grep -qF "Release archive does not contain an executable XrayR binary" "$repo_root/install-machine.sh" || fail "machine archive validation missing"
work=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-transaction-test.XXXXXX")
install_dir="$work/install"
config_dir="$work/config"
config_file="$config_dir/config.yml"
mkdir -p "$install_dir" "$config_dir"
printf old-version > "$install_dir/XrayR"
source "$repo_root/install-machine.sh"
install_dir="$work/install"
config_dir="$work/config"
config_file="$work/config/config.yml"
arch_name=64
version=v-test
release_repo=example/release
systemctl(){ return 0; }
curl(){ return 1; }
if (download_and_install_release) >"$work/download-failure.out" 2>&1; then fail "download failure was accepted"; fi
grep -qF old-version "$install_dir/XrayR" || fail "download failure removed the previous install"
curl(){
    local out="" url="";
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-o" ]]; then out="$2"; shift 2;
        elif [[ "$1" == http* ]]; then url="$1"; shift;
        else shift; fi
    done
    if [[ "$url" == *SHA256SUMS ]]; then
        printf '%s  %s\n' "$(printf fake-archive | sha256sum | awk '{print $1}')" XrayR-linux-64.zip > "$out"
    else
        printf fake-archive > "$out"
    fi
}
unzip(){ return 1; }
if (download_and_install_release) >"$work/extract-failure.out" 2>&1; then fail "extract failure was accepted"; fi
grep -qF old-version "$install_dir/XrayR" || fail "extract failure removed the previous install"
unzip(){ local dest=""; while [[ $# -gt 0 ]]; do if [[ "$1" == "-d" ]]; then dest="$2"; shift 2; else shift; fi; done; printf new-version > "$dest/XrayR"; chmod +x "$dest/XrayR"; }
download_and_install_release >/dev/null
grep -qF new-version "$install_dir/XrayR" || fail "staged release was not activated"
rollback_installation
grep -qF old-version "$install_dir/XrayR" || fail "rollback did not restore previous install"
echo "PASS: transactional installer staging and rollback"
