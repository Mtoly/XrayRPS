#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="${XRAYR_TEST_INSTALLER:-$repo_root/install.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }

for manager in systemd openrc; do
    for failure in config.yml route.json geoip.dat service; do
        (
            work=$(mktemp -d)
            trap 'rm -rf -- "$work"' EXIT
            XRAYR_TEST_MODE=1 source "$installer"
            install_dir="$work/install"
            config_dir="$work/config"
            service_file="$work/service"
            cur_dir="$work/download"
            service_manager="$manager"
            arch=64
            mkdir -p "$cur_dir"
            state=stopped
            if [[ "$failure" != config.yml ]]; then
                mkdir -p "$install_dir" "$config_dir"
                printf old-binary > "$install_dir/XrayR"
                printf fixture-private-config > "$config_dir/config.yml"
                printf original-service > "$service_file"
                state=active
            fi
            printf '%s' "$state" > "$work/state"
            printf false > "$work/enabled"
            if [[ "$manager" == openrc ]]; then asset=XrayR.openrc; else asset=XrayR.service; fi
            cp "$repo_root/$asset" "$cur_dir/$asset"
            service_control() {
                case "$1" in
                    is-active) [[ $(<"$work/state") == active ]] ;;
                    is-enabled) [[ $(<"$work/enabled") == true ]] ;;
                    start) printf active > "$work/state" ;;
                    stop) printf stopped > "$work/state" ;;
                    enable) printf true > "$work/enabled" ;;
                    disable) printf false > "$work/enabled" ;;
                    daemon-reload) : ;;
                esac
            }
            download_release_artifact() { printf archive > "$3"; }
            download_https() { printf '#!/bin/bash\n' > "$2"; }
            unzip() {
                local destination
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == -d ]]; then destination="$2"; break; fi
                    shift
                done
                printf new-binary > "$destination/XrayR"
                chmod 0755 "$destination/XrayR"
                for file in config.yml dns.json route.json custom_outbound.json custom_inbound.json rulelist geoip.dat; do
                    printf fixture > "$destination/$file"
                done
            }
            cp() {
                if [[ "${*: -1}" == "$config_dir/" && " $* " == *" $failure "* ]] ||
                    [[ "$failure" == service && " $* " == *" $cur_dir/$asset "* ]]; then
                    echo "fixture copy error" >&2
                    return 1
                fi
                command cp "$@"
            }
            install() {
                local source="${*: -2:1}" destination="${*: -1}"
                [[ "$destination" != /usr/bin/XrayR ]] || destination="$work/management"
                command cp "$source" "$destination"
            }
            ensure_service_permissions() { :; }
            ln() { :; }
            chmod() {
                [[ "${*: -1}" != /usr/bin/xrayr ]] || return 0
                command chmod "$@"
            }
            sleep() { :; }
            if (install_XrayR 0.9.5) > "$work/output" 2>&1; then fail "$manager/$failure copy error accepted"; fi
            grep -q 'Failed to copy' "$work/output" || fail "copy failure was not explicitly reported"
            [[ $(<"$work/state") == "$state" && $(<"$work/enabled") == false ]] || fail "prior service state lost"
            if [[ "$failure" == config.yml ]]; then
                [[ ! -d "$install_dir" && ! -d "$config_dir" && ! -f "$service_file" ]] || fail "fresh failure left activated files"
            else
                [[ $(<"$install_dir/XrayR") == old-binary ]] || fail "binary lost"
                [[ $(<"$config_dir/config.yml") == fixture-private-config ]] || fail "existing config lost"
                [[ $(<"$service_file") == original-service ]] || fail "service definition lost"
            fi
            [[ ! -f "$work/management" ]] || fail "failed install updated management script"
            if grep -q fixture-private-config "$work/output"; then fail "copy error exposed configuration contents"; fi
        )
    done
done
echo "PASS: config/default/data/service copy failures abort and restore fresh/upgrade installations on both managers"
