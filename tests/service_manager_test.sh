#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Standalone downloads must use exactly the same manager rules.
for script in install.sh install-machine.sh XrayR.sh; do
    sed -n '/^# Keep this block identical/,/^# End standalone service-manager block/p' "$repo_root/$script" > "$work/$script"
done
cmp "$work/install.sh" "$work/install-machine.sh"
cmp "$work/install.sh" "$work/XrayR.sh"

source "$work/install.sh"
export XRAYR_TEST_MODE=1 XRAYR_INIT_ROOT="$work/runtime"
mkdir -p "$XRAYR_INIT_ROOT/run/openrc"
systemctl() { return 0; }
rc-service() { return 0; }
rc-update() { return 0; }
supervise-daemon() { return 0; }
if detect_service_manager 2>"$work/unsupported"; then
    fail "installed commands without runtime markers were accepted"
fi
grep -q 'Unsupported init environment' "$work/unsupported"
printf default > "$XRAYR_INIT_ROOT/run/openrc/softlevel"
detect_service_manager
[[ "$service_manager" == openrc && "$service_file" == /etc/init.d/XrayR ]] || fail "OpenRC not detected"

# Check the public command, so the menu wrapper cannot hide manager failures.
(
    systemctl() { return 1; }
    rc-service() { return 0; }
    supervise-daemon() { return 0; }
    rc-update() {
        case "$MOCK_DISABLE_STATE/$1" in
            absent/show) return 0 ;;
            query-error/show) return 1 ;;
            delete-error/show) printf ' XrayR | default\n' ;;
            *) return 1 ;;
        esac
    }
    export -f systemctl rc-service supervise-daemon rc-update
    export XRAYR_SERVICE_FILE="$work/cli-service"
    touch "$XRAYR_SERVICE_FILE"
    for MOCK_DISABLE_STATE in absent query-error delete-error; do
        export MOCK_DISABLE_STATE
        result=0
        bash "$repo_root/XrayR.sh" disable > "$work/disable-$MOCK_DISABLE_STATE.out" 2>&1 || result=$?
        if [[ "$MOCK_DISABLE_STATE" == absent ]]; then
            [[ "$result" == 0 ]] || fail "CLI already-disabled state failed"
        else
            [[ "$result" != 0 ]] || fail "CLI $MOCK_DISABLE_STATE was hidden"
        fi
    done
)

rc-update() { [[ "$1" == show ]]; }
service_control disable || fail "already disabled service did not succeed"
rc-update() { return 1; }
if service_control disable; then fail "runlevel query failure was ignored"; fi
rc-update() {
    if [[ "$1" == show ]]; then printf ' XrayR | default\n'; else return 1; fi
}
if service_control disable; then fail "runlevel removal failure was ignored"; fi
rc-update() { return 0; }
mkdir -p "$XRAYR_INIT_ROOT/run/systemd/system"
detect_service_manager
[[ "$service_manager" == systemd ]] || fail "running systemd not preferred"
systemctl() { return 1; }
detect_service_manager
[[ "$service_manager" == openrc ]] || fail "inactive systemd accepted based only on its directory"
unset -f supervise-daemon
rm -rf -- "$XRAYR_INIT_ROOT/run/systemd"
if detect_service_manager 2>/dev/null; then
    fail "OpenRC accepted without its native supervisor"
fi

for manager in systemd openrc; do
    for initial in active stopped; do
        (
            source "$repo_root/install-machine.sh"
            service_manager="$manager"
            cur_dir="$repo_root"
            service_file="$work/service"
            config_dir="$work/config"
            mkdir -p "$config_dir"
            printf 'original-service\n' > "$service_file"
            printf 'MachineConfig:\n  MachineID: 7\n  ApiHost: https://example.invalid\n  Token: fixture-secret\n' > "$config_dir/config.yml"
            state="$initial"
            enabled=false
            service_control() {
                case "$1" in
                    is-active) [[ "$state" == active ]] ;;
                    is-enabled) [[ "$enabled" == true ]] ;;
                    start) state=active ;;
                    stop) state=stopped ;;
                    enable) enabled=true ;;
                    disable) enabled=false ;;
                    daemon-reload) : ;;
                esac
            }
            snapshot_service_state "$work/snapshot-$manager-$initial"
            install_service
            [[ "$manager" != openrc ]] || [[ -x "$service_file" ]] || fail "OpenRC service is not executable"
            printf changed > "$config_dir/config.yml"
            state=stopped
            enabled=true
            restore_service_state "$work/snapshot-$manager-$initial"
            [[ "$state" == "$initial" && "$enabled" == false ]] || fail "previous service state not restored"
            grep -qx original-service "$service_file"
            grep -q fixture-secret "$config_dir/config.yml"
        )
    done
done
echo "PASS: identical runtime detection, unsupported init, native definitions and prior active/stopped/autostart/config restoration"

# Execute both installer failure paths with both managers and prior service states.
# These are filesystem/command mocks; actual OpenRC runs in the container suite.
for script in install.sh install-machine.sh; do
    for manager in systemd openrc; do
        for initial in active stopped; do
            (
                XRAYR_TEST_MODE=1 source "$repo_root/$script"
                case_dir="$work/$script-$manager-$initial"
                mkdir -p "$case_dir/install" "$case_dir/config" "$case_dir/download"
                service_manager="$manager"
                install_dir="$case_dir/install"
                config_dir="$case_dir/config"
                config_file="$config_dir/config.yml"
                service_file="$case_dir/service"
                cur_dir="$case_dir/download"
                arch=64
                arch_name=64
                printf old-binary > "$install_dir/XrayR"
                chmod 0755 "$install_dir/XrayR"
                printf original-service > "$service_file"
                printf 'MachineConfig:\n  MachineID: 7\n  ApiHost: https://original.example.invalid\n  Token: fixture-original-secret\n' > "$config_file"
                cp "$config_file" "$case_dir/original-config"
                printf '%s' "$initial" > "$case_dir/state"
                printf '%s' "$initial" > "$case_dir/enabled"
                service_control() {
                    case "$1" in
                        is-active) [[ $(<"$case_dir/state") == active ]] ;;
                        is-enabled) [[ $(<"$case_dir/enabled") == active ]] ;;
                        stop) printf stopped > "$case_dir/state" ;;
                        start)
                            [[ $(<"$install_dir/XrayR") == old-binary ]] || return 1
                            printf active > "$case_dir/state"
                            ;;
                        enable) printf active > "$case_dir/enabled" ;;
                        disable) printf stopped > "$case_dir/enabled" ;;
                        daemon-reload) : ;;
                    esac
                }
                download_release_artifact() { printf archive > "$3"; }
                download_https() { printf archive > "$2"; }
                curl() {
                    while [[ $# -gt 0 ]]; do
                        if [[ "$1" == -o ]]; then printf replacement-service > "$2"; return; fi
                        shift
                    done
                }
                verify_release_checksum() { return 0; }
                unzip() {
                    local destination
                    while [[ $# -gt 0 ]]; do
                        if [[ "$1" == -d ]]; then destination="$2"; break; fi
                        shift
                    done
                    printf new-binary > "$destination/XrayR"
                    chmod 0755 "$destination/XrayR"
                    for file in dns.json route.json custom_outbound.json custom_inbound.json rulelist; do
                        printf fixture > "$destination/$file"
                    done
                }
                ensure_service_permissions() { return 0; }
                install_base() { :; }
                validate_machine() { :; }
                require_root() { :; }
                require_service_manager() { :; }
                detect_os() { :; }
                detect_arch() { :; }
                install_management_script() { :; }
                sleep() { :; }
                if [[ "$script" == install.sh ]]; then
                    if (install_XrayR 0.9.5) > "$case_dir/output" 2>&1; then fail "failed standard start accepted"; fi
                else
                    if (main --api-host https://changed.example.invalid --machine-id 8 \
                        --token fixture-replacement-secret --force --version 0.9.5) > "$case_dir/output" 2>&1; then
                        fail "failed Machine start accepted"
                    fi
                fi
                [[ $(<"$install_dir/XrayR") == old-binary ]] || fail "$script/$manager lost original binary"
                [[ $(<"$case_dir/state") == "$initial" ]] || fail "$script/$manager lost prior active state"
                [[ $(<"$case_dir/enabled") == "$initial" ]] || fail "$script/$manager lost autostart state"
                [[ $(<"$service_file") == original-service ]] || fail "$script/$manager lost service definition"
                cmp "$config_file" "$case_dir/original-config"
                if grep -q 'fixture-.*-secret' "$case_dir/output"; then fail "installer leaked fixture token"; fi
            )
        done
    done
done
echo "PASS: standard/Machine failed starts restore binary, definition, configuration and prior active/stopped/autostart states on both managers"
