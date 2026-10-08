#!/bin/bash
# Run only in a disposable Alpine container; never on a real node.
set -euo pipefail
[[ -f /.dockerenv && -f /etc/alpine-release && $(id -u) == 0 ]] || {
    echo "This test requires a disposable root Alpine Docker container." >&2
    exit 1
}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rc-service XrayR stop >/dev/null 2>&1 || true; rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The container is not an OpenRC PID 1 boot. Supply only the network dependency,
# then initialize OpenRC state with its own runlevel command.
printf 'rc_sys="docker"\n' >> /etc/rc.conf
printf '#!/sbin/openrc-run\ndepend() { provide net; }\nstart() { return 0; }\n' > /etc/init.d/test-network
chmod 0755 /etc/init.d/test-network
rc-update add test-network default
openrc default

python3 - "$repo_root" "$work" <<'PY'
import pathlib
import sys
import zipfile
root, work = map(pathlib.Path, sys.argv[1:])
with zipfile.ZipFile(work / "release.zip", "w") as archive:
    info = zipfile.ZipInfo("XrayR")
    info.external_attr = 0o100755 << 16
    archive.writestr(info, (root / "tests/fixtures/xrayr_process.py").read_bytes())
    for file in (root / "config").iterdir():
        if file.is_file():
            archive.write(file, file.name)
PY
printf '%s  XrayR-linux-64.zip\n' "$(sha256sum "$work/release.zip" | cut -d' ' -f1)" > "$work/SHA256SUMS"
fixture_download() {
    case "$1" in
        *XrayR-linux-64.zip) cp "$work/release.zip" "$2" ;;
        *SHA256SUMS) cp "$work/SHA256SUMS" "$2" ;;
        *XrayR.openrc) cp "$repo_root/XrayR.openrc" "$2" ;;
        *XrayR.sh) cp "$repo_root/XrayR.sh" "$2" ;;
        *) echo "Unexpected network request: $1" >&2; return 1 ;;
    esac
}
wait_child() {
    local attempt
    for attempt in {1..30}; do
        if [[ -s /run/xrayr-child.pid ]] && kill -0 "$(cat /run/xrayr-child.pid)" 2>/dev/null; then return 0; fi
        sleep 1
    done
    fail "supervised process did not appear"
}

(
    XRAYR_TEST_MODE=1 source "$repo_root/install.sh"
    detect_service_manager
    [[ "$service_manager" == openrc ]] || fail "installer did not detect actual OpenRC"
    arch=64
    cur_dir="$work"
    download_https() { fixture_download "$@"; }
    install_XrayR 0.9.5 > "$work/ordinary.out" 2>&1
)
[[ -x /etc/init.d/XrayR ]] || fail "ordinary install did not install OpenRC service"
XrayR start
wait_child
XrayR status > "$work/status.out"
grep -q '系统服务：运行中' "$work/status.out"
XrayR restart
wait_child
XrayR stop
if rc-service XrayR status; then fail "stop left service running"; fi
XrayR enable
rc-update show default | grep XrayR >/dev/null
XrayR disable
XrayR disable
if rc-update show default | grep XrayR >/dev/null; then fail "disable retained autostart"; fi
XrayR start
wait_child
if timeout 2 XrayR log > "$work/log.out"; then
    :
else
    timeout_status=$?
    # BusyBox reports SIGTERM as 143; GNU timeout uses 124.
    [[ "$timeout_status" == 124 || "$timeout_status" == 143 ]]
fi
grep -q fixture-started "$work/log.out"
grep -q fixture-stderr "$work/log.out"
[[ $(stat -c %a /var/log/XrayR) == 750 ]]
[[ $(stat -c %a /var/log/XrayR/output.log) == 640 ]]
old_pid=$(cat /run/xrayr-child.pid)
kill -KILL "$old_pid"
for attempt in {1..25}; do
    sleep 1
    [[ $(cat /run/xrayr-child.pid) == "$old_pid" ]] || break
done
[[ $(cat /run/xrayr-child.pid) != "$old_pid" ]] || fail "supervise-daemon did not respawn the process"
wait_child
echo "PASS: actual OpenRC ordinary install, start/stop/restart/status, autostart, logs, permissions and crash respawn"

XrayR stop
rm -f /etc/XrayR/config.yml
(
    source "$repo_root/install-machine.sh"
    cur_dir="$repo_root"
    install_base() { :; } # Image already contains the runtime dependencies.
    validate_machine() { :; } # No real Xboard request in integration tests.
    download_https() { fixture_download "$@"; }
    main --api-host https://panel.example.invalid --machine-id 7 \
        --token fixture-machine-secret --version 0.9.5
) > "$work/machine.out" 2>&1
wait_child
grep -q 'MachineID: 7' /etc/XrayR/config.yml
grep -q 'Token: "fixture-machine-secret"' /etc/XrayR/config.yml
grep -q 'ApiHost: "https://panel.example.invalid"' /etc/XrayR/config.yml
if grep -q fixture-machine-secret "$work/machine.out"; then fail "installer printed the token"; fi
before=$(sha256sum /etc/XrayR/config.yml)
binary_before=$(sha256sum /usr/local/XrayR/XrayR)

# The CLI must keep its existing no-overwrite contract without --force.
if (
    source "$repo_root/install-machine.sh"
    install_base() { fail "dependencies invoked before overwrite refusal"; }
    validate_machine() { fail "panel validation invoked before overwrite refusal"; }
    main --api-host https://panel.example.invalid --machine-id 7 \
        --token fixture-machine-secret --version 0.9.5
) > "$work/no-force.out" 2>&1; then fail "existing config overwritten without --force"; fi
grep -q 'already exists' "$work/no-force.out"
[[ $(sha256sum /etc/XrayR/config.yml) == "$before" ]]

# Standard update/repeat install must retain MachineConfig.
(
    XRAYR_TEST_MODE=1 source "$repo_root/install.sh"
    detect_service_manager
    arch=64
    cur_dir="$work"
    download_https() { fixture_download "$@"; }
    install_XrayR v0.9.5
) > "$work/repeat.out" 2>&1
[[ $(sha256sum /etc/XrayR/config.yml) == "$before" ]] || fail "ordinary update changed MachineConfig"
wait_child

# Fail the new service installation after staging; restore binary and active state.
if (
    XRAYR_TEST_MODE=1 source "$repo_root/install.sh"
    detect_service_manager
    arch=64
    cur_dir="$work"
    download_https() {
        [[ "$1" != *XrayR.openrc ]] || return 1
        fixture_download "$@"
    }
    install_XrayR 0.9.5
) > "$work/failure.out" 2>&1; then fail "failed update was accepted"; fi
[[ $(sha256sum /usr/local/XrayR/XrayR) == "$binary_before" ]] || fail "binary not restored"
[[ $(sha256sum /etc/XrayR/config.yml) == "$before" ]] || fail "config not restored"
rc-service XrayR status
wait_child

# Machine --force failure restores original config and service, with no panel call.
if (
    source "$repo_root/install-machine.sh"
    cur_dir="$repo_root"
    install_base() { :; }
    validate_machine() { :; }
    download_https() { fixture_download "$@"; }
    start_service() { return 1; } # Fail after --force wrote the new config.
    main --api-host https://changed.example.invalid --machine-id 8 \
        --token fixture-replacement-secret --version 0.9.5 --force
) > "$work/machine-failure.out" 2>&1; then fail "machine failure accepted"; fi
[[ $(sha256sum /etc/XrayR/config.yml) == "$before" ]] || fail "force failure lost original credentials"
rc-service XrayR status
wait_child
XrayR stop
echo "PASS: actual OpenRC MachineConfig, repeated update preservation and ordinary/Machine failure rollback"
XrayR disable
XrayR disable
printf 'y\n' | XrayR uninstall
[[ ! -e /etc/init.d/XrayR && ! -d /usr/local/XrayR && ! -d /etc/XrayR ]] || fail "disabled-service uninstall left deployment files"
echo "PASS: actual OpenRC repeated disable and uninstall after disable"
echo "LIMIT: fixture executable, no XrayRP binary/panel/VPS; OpenRC is initialized under Docker, no PID 1 boot or host reboot validation"
