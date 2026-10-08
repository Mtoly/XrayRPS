#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="${XRAYR_TEST_INSTALLER:-$repo_root/install-machine.sh}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

for manager in systemd openrc; do
    for previous in symlink file absent; do
        for outcome in failure success; do
            case_dir="$work/$manager-$previous-$outcome"
            mkdir -p "$case_dir/bin" "$case_dir/source" "$case_dir/config"
            printf '#!/bin/bash\necho new-management\n' > "$case_dir/candidate"
            if [[ "$previous" != absent ]]; then
                mkdir -p "$case_dir/install"
                printf old-binary > "$case_dir/install/XrayR"
                printf 'MachineConfig:\n  MachineID: 7\n  ApiHost: https://old.example.invalid\n  Token: fixture-original-secret\n' > "$case_dir/config/config.yml"
                cp "$case_dir/config/config.yml" "$case_dir/original-config"
                printf original-service > "$case_dir/service"
                printf '#!/bin/bash\necho old-management\n' > "$case_dir/bin/XrayR"
                chmod 0750 "$case_dir/bin/XrayR"
                cp -p "$case_dir/bin/XrayR" "$case_dir/original-script"
                if [[ "$previous" == symlink ]]; then
                    ln -s XrayR "$case_dir/bin/xrayr"
                else
                    printf old-alias > "$case_dir/bin/xrayr"
                    chmod 0700 "$case_dir/bin/xrayr"
                    cp -p "$case_dir/bin/xrayr" "$case_dir/original-alias"
                fi
                printf active > "$case_dir/state"
                printf true > "$case_dir/enabled"
                cp "$case_dir/candidate" "$case_dir/source/XrayR.sh"
            else
                printf stopped > "$case_dir/state"
                printf false > "$case_dir/enabled"
            fi

            result=0
            # Child shell preserves the installer's errexit semantics; all paths
            # and service/network commands below belong to this local fixture.
            bash -s -- "$installer" "$case_dir" "$manager" "$outcome" <<'SH' > "$case_dir/stdout" 2> "$case_dir/stderr" || result=$?
source "$1"
case_dir="$2"
service_manager="$3"
outcome="$4"
cur_dir="$case_dir/source"
install_dir="$case_dir/install"
config_dir="$case_dir/config"
config_file="$config_dir/config.yml"
service_file="$case_dir/service"
management_script="$case_dir/bin/XrayR"
management_link="$case_dir/bin/xrayr"
arch_name=64
require_root() { :; }
require_service_manager() { :; }
require_systemd() { :; } # Also run this reproduction against the main baseline.
detect_os() { :; }
detect_arch() { :; }
install_base() { :; }
validate_machine() { :; }
ensure_service_permissions() { :; }
download_https() { printf archive > "$2"; }
verify_release_checksum() { :; }
unzip() {
    local destination="${*: -1}"
    printf new-binary > "$destination/XrayR"
    chmod 0755 "$destination/XrayR"
}
install_service() { printf new-service > "$service_file"; }
curl() {
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -o ]]; then cp "$case_dir/candidate" "$2"; return; fi
        shift
    done
    return 1
}
# Remap the baseline's hardcoded lowercase alias into the fixture too.
ln() {
    local destination="${*: -1}"
    [[ "$destination" != /usr/bin/xrayr ]] || destination="$management_link"
    command ln "${@:1:$#-1}" "$destination"
}
chmod() {
    local destination="${*: -1}"
    [[ "$destination" != /usr/bin/xrayr ]] || destination="$management_link"
    command chmod "${@:1:$#-1}" "$destination"
}
service_control() {
    case "$1" in
        is-active) [[ $(<"$case_dir/state") == active ]] ;;
        is-enabled) [[ $(<"$case_dir/enabled") == true ]] ;;
        stop) printf stopped > "$case_dir/state" ;;
        start) printf active > "$case_dir/state" ;;
        enable) printf true > "$case_dir/enabled" ;;
        disable) printf false > "$case_dir/enabled" ;;
        daemon-reload) : ;;
    esac
}
systemctl() { service_control "$@"; }
start_service() {
    cmp "$management_script" "$case_dir/candidate" || return 1
    [[ -L "$management_link" && $(readlink "$management_link") == "$management_script" ]] || return 1
    echo management-update-completed
    [[ "$outcome" != failure ]] || return 1
    service_control start
}
main --api-host https://new.example.invalid --machine-id 8 \
    --token fixture-replacement-secret --version 0.9.5 --force
SH
            grep -q '^management-update-completed$' "$case_dir/stdout" || fail "$manager/$previous did not reach the post-management start failure"
            if [[ "$outcome" == success ]]; then
                [[ "$result" == 0 ]] || fail "$manager/$previous successful installation failed"
                cmp "$case_dir/candidate" "$case_dir/bin/XrayR" || fail "success lost new management script"
                [[ -L "$case_dir/bin/xrayr" ]] || fail "success lost lowercase alias"
            else
                [[ "$result" != 0 ]] || fail "start failure accepted"
                if [[ "$previous" == absent ]]; then
                    [[ ! -e "$case_dir/bin/XrayR" && ! -L "$case_dir/bin/xrayr" && ! -e "$case_dir/bin/xrayr" ]] || fail "$manager fresh rollback left management files"
                else
                    cmp -s "$case_dir/original-script" "$case_dir/bin/XrayR" || fail "$manager rollback kept new management script"
                    [[ $(stat -c %a "$case_dir/bin/XrayR") == 750 ]] || fail "rollback changed original script permissions"
                    if [[ "$previous" == symlink ]]; then
                        [[ -L "$case_dir/bin/xrayr" && $(readlink "$case_dir/bin/xrayr") == XrayR ]] || fail "rollback changed original alias target"
                    else
                        cmp "$case_dir/original-alias" "$case_dir/bin/xrayr" || fail "rollback lost original alias file"
                        [[ $(stat -c %a "$case_dir/bin/xrayr") == 700 ]] || fail "rollback changed alias permissions"
                    fi
                    cmp "$case_dir/original-config" "$case_dir/config/config.yml"
                    [[ $(<"$case_dir/install/XrayR") == old-binary && $(<"$case_dir/service") == original-service ]] || fail "prior binary/service lost"
                    [[ $(<"$case_dir/state") == active && $(<"$case_dir/enabled") == true ]] || fail "prior service state lost"
                fi
            fi
            if grep -q 'fixture-.*-secret' "$case_dir/stdout" "$case_dir/stderr"; then fail "token exposed"; fi
        done
    done
done
echo "PASS: Machine post-management start failure restores script bytes/mode/alias or initial absence; successful installs publish new script on both managers"
