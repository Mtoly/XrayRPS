#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail(){ echo "FAIL: $*" >&2; exit 1; }

assert_service_identity() {
  local service_path="$1"
  grep -qF 'User=root' "$service_path" || fail "$service_path does not use User=root"
  grep -qF 'Group=root' "$service_path" || fail "$service_path does not use Group=root"
  ! grep -qF 'User=xrayr' "$service_path" || fail "$service_path still uses User=xrayr"
  ! grep -qF 'Group=xrayr' "$service_path" || fail "$service_path still uses Group=xrayr"
}

assert_service_identity "$repo_root/XrayR.service"
! grep -qF 'CAP_NET_BIND_SERVICE' "$repo_root/XrayR.service" || fail 'root compatibility must not add a low-port capability workaround'

account_symbols='service_user_exists|service_group_exists|service_nologin_shell|command_is_busybox|create_service_group|create_service_user|ensure_service_account|XRAYR_SERVICE_USER|XRAYR_SERVICE_GROUP'
for installer in "$repo_root/install.sh" "$repo_root/install-machine.sh"; do
  if grep -nE "$account_symbols" "$installer"; then
    fail "$installer still contains dedicated service-account provisioning"
  fi
  if grep -nE '(^|[^[:alnum:]_])(useradd|groupadd|adduser|addgroup)([^[:alnum:]_]|$)' "$installer"; then
    fail "$installer still invokes account-management commands"
  fi
  if grep -nE '(^|[^[:alnum:]_])(userdel|groupdel|deluser|delgroup)([^[:alnum:]_]|$)' "$installer"; then
    fail "$installer deletes an existing xrayr account"
  fi
done

run_permission_case() (
  local installer="$1"
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-root-permissions.XXXXXX")
  trap 'rm -rf -- "$state"' EXIT

  XRAYR_TEST_MODE=1 source "$installer"
  export XRAYR_INSTALL_DIR="$state/install"
  export XRAYR_CONFIG_DIR="$state/config"
  export XRAYR_STATE_DIR="$state/state"
  mkdir -p "$XRAYR_INSTALL_DIR" "$XRAYR_CONFIG_DIR/cert" "$XRAYR_STATE_DIR"
  printf binary > "$XRAYR_INSTALL_DIR/XrayR"
  printf runtime-data > "$XRAYR_INSTALL_DIR/existing.dat"
  printf preserved-config > "$XRAYR_CONFIG_DIR/config.yml"
  printf preserved-cert > "$XRAYR_CONFIG_DIR/cert/server.key"
  printf preserved-state > "$XRAYR_STATE_DIR/existing.state"
  chmod 0755 "$XRAYR_INSTALL_DIR/XrayR"

  local before_config before_cert before_state
  before_config=$(sha256sum "$XRAYR_CONFIG_DIR/config.yml" | awk '{print $1}')
  before_cert=$(sha256sum "$XRAYR_CONFIG_DIR/cert/server.key" | awk '{print $1}')
  before_state=$(sha256sum "$XRAYR_STATE_DIR/existing.state" | awk '{print $1}')
  : > "$state/commands"

  install(){
    local make_dirs=false mode="" owner="" group=""
    local paths=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -d) make_dirs=true; shift ;;
        -o) owner="$2"; shift 2 ;;
        -g) group="$2"; shift 2 ;;
        -m) mode="$2"; shift 2 ;;
        -*) shift ;;
        *) paths+=("$1"); shift ;;
      esac
    done
    printf 'install owner=%s group=%s mode=%s paths=%s\n' "$owner" "$group" "$mode" "${paths[*]}" >> "$state/commands"
    if [[ "$make_dirs" == true ]]; then
      mkdir -p "${paths[@]}"
      [[ -z "$mode" ]] || chmod "$mode" "${paths[@]}"
    fi
  }
  chown(){ printf 'chown %s\n' "$*" >> "$state/commands"; }
  useradd(){ echo useradd >> "$state/commands"; return 99; }
  groupadd(){ echo groupadd >> "$state/commands"; return 99; }
  adduser(){ echo adduser >> "$state/commands"; return 99; }
  addgroup(){ echo addgroup >> "$state/commands"; return 99; }

  ensure_service_permissions
  ensure_service_permissions

  grep -qF "chown -R root:root $XRAYR_INSTALL_DIR" "$state/commands" || fail "$installer runtime ownership is not root:root"
  grep -qF "chown -R root:root $XRAYR_CONFIG_DIR" "$state/commands" || fail "$installer config ownership is not root:root"
  grep -qF "chown -R root:root $XRAYR_STATE_DIR" "$state/commands" || fail "$installer state ownership is not root:root"
  ! grep -Eq '^(useradd|groupadd|adduser|addgroup)$' "$state/commands" || fail "$installer depends on an xrayr account"

  [[ $(stat -c %a "$XRAYR_INSTALL_DIR") == 750 ]] || fail "$installer runtime directory mode is not 0750"
  [[ $(stat -c %a "$XRAYR_INSTALL_DIR/XrayR") == 750 ]] || fail "$installer binary mode is not 0750"
  [[ $(stat -c %a "$XRAYR_CONFIG_DIR/cert") == 750 ]] || fail "$installer certificate directory mode is not 0750"
  [[ $(stat -c %a "$XRAYR_CONFIG_DIR/cert/server.key") == 640 ]] || fail "$installer certificate mode is not 0640"
  [[ $(stat -c %a "$XRAYR_STATE_DIR") == 750 ]] || fail "$installer state directory mode is not 0750"

  [[ $(sha256sum "$XRAYR_CONFIG_DIR/config.yml" | awk '{print $1}') == "$before_config" ]] || fail "$installer changed existing configuration"
  [[ $(sha256sum "$XRAYR_CONFIG_DIR/cert/server.key" | awk '{print $1}') == "$before_cert" ]] || fail "$installer changed an existing certificate/key"
  [[ $(sha256sum "$XRAYR_STATE_DIR/existing.state" | awk '{print $1}') == "$before_state" ]] || fail "$installer changed existing state data"
)

for installer in "$repo_root/install.sh" "$repo_root/install-machine.sh"; do
  grep -q '^ensure_service_permissions()' "$installer" || fail "$installer is missing root ownership repair"
  run_permission_case "$installer"
done

simulate_service_install() {
  local previous_user="$1"
  local account_state="$2"
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-root-service.XXXXXX")
  if [[ "$previous_user" != none ]]; then
    printf '[Service]\nUser=%s\nGroup=%s\n' "$previous_user" "$previous_user" > "$state/XrayR.service"
  fi
  if [[ "$account_state" == present ]]; then
    : > "$state/xrayr-user-exists"
  fi
  install -m 0644 "$repo_root/XrayR.service" "$state/XrayR.service"
  assert_service_identity "$state/XrayR.service"
  local first_hash
  first_hash=$(sha256sum "$state/XrayR.service" | awk '{print $1}')
  install -m 0644 "$repo_root/XrayR.service" "$state/XrayR.service"
  [[ $(sha256sum "$state/XrayR.service" | awk '{print $1}') == "$first_hash" ]] || fail 'repeated service installation is not idempotent'
  rm -rf -- "$state"
}

simulate_service_install none absent
simulate_service_install root absent
simulate_service_install xrayr absent
simulate_service_install xrayr present
simulate_service_install root present

assert_standard_install_flow() (
  local previous_user="$1"
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-standard-root.XXXXXX")
  trap 'rm -rf -- "$state"' EXIT

  XRAYR_TEST_MODE=1 source "$repo_root/install.sh"
  export XRAYR_INSTALL_DIR="$state/install"
  export XRAYR_CONFIG_DIR="$state/config"
  install_dir="$XRAYR_INSTALL_DIR"
  config_dir="$XRAYR_CONFIG_DIR"
  service_file="$state/XrayR.service"
  export XRAYR_STATE_DIR="$state/state"
  cur_dir="$state/work"
  arch=64
  mkdir -p "$cur_dir" "$XRAYR_STATE_DIR"
  : > "$state/systemctl.log"

  if [[ "$previous_user" != none ]]; then
    mkdir -p "$install_dir" "$config_dir/cert"
    printf old-binary > "$install_dir/XrayR"
    printf preserved-config > "$config_dir/config.yml"
    printf preserved-cert > "$config_dir/cert/server.key"
    printf preserved-state > "$XRAYR_STATE_DIR/existing.state"
    printf '[Service]\nUser=%s\nGroup=%s\n' "$previous_user" "$previous_user" > "$service_file"
  fi

  local config_hash="" cert_hash="" state_hash=""
  if [[ "$previous_user" != none ]]; then
    config_hash=$(sha256sum "$config_dir/config.yml" | awk '{print $1}')
    cert_hash=$(sha256sum "$config_dir/cert/server.key" | awk '{print $1}')
    state_hash=$(sha256sum "$XRAYR_STATE_DIR/existing.state" | awk '{print $1}')
  fi

  check_status(){ [[ "$previous_user" != none ]]; }
  validate_release_version(){ return 0; }
  download_release_artifact(){ printf archive > "$3"; }
  unzip(){
    local destination=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -d ]]; then destination="$2"; shift 2; else shift; fi
    done
    mkdir -p "$destination"
    printf new-binary > "$destination/XrayR"
    chmod +x "$destination/XrayR"
    printf default-config > "$destination/config.yml"
    printf geoip > "$destination/geoip.dat"
    printf geosite > "$destination/geosite.dat"
    printf dns > "$destination/dns.json"
    printf route > "$destination/route.json"
    printf outbound > "$destination/custom_outbound.json"
    printf inbound > "$destination/custom_inbound.json"
    printf rules > "$destination/rulelist"
  }
  download_https(){
    local url="$1" destination="$2"
    if [[ "$url" == *XrayR.service ]]; then
      cp "$repo_root/XrayR.service" "$destination"
    else
      printf '#!/bin/bash\n' > "$destination"
    fi
  }
  install(){
    local make_dirs=false mode="" owner="" group="" source="" destination=""
    local paths=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -d) make_dirs=true; shift ;;
        -o) owner="$2"; shift 2 ;;
        -g) group="$2"; shift 2 ;;
        -m) mode="$2"; shift 2 ;;
        -*) shift ;;
        *) paths+=("$1"); shift ;;
      esac
    done
    if [[ "$make_dirs" == true ]]; then
      mkdir -p "${paths[@]}"
      [[ -z "$mode" ]] || chmod "$mode" "${paths[@]}"
      return
    fi
    source="${paths[0]}"
    destination="${paths[1]}"
    [[ "$destination" != /usr/bin/XrayR ]] || destination="$state/XrayR-management"
    cp "$source" "$destination"
    [[ -z "$mode" ]] || chmod "$mode" "$destination"
  }
  chown(){ :; }
  ln(){ :; }
  chmod(){
    [[ " ${*} " != *' /usr/bin/xrayr '* ]] || return 0
    command chmod "$@"
  }
  systemctl(){ printf '%s\n' "$*" >> "$state/systemctl.log"; }
  sleep(){ :; }

  install_XrayR v0.9.2 >/dev/null

  assert_service_identity "$service_file"
  grep -qF new-binary "$install_dir/XrayR" || fail "standard installer did not activate the new release from ${previous_user}"
  grep -qF daemon-reload "$state/systemctl.log" || fail 'standard installer did not daemon-reload after service replacement'

  if [[ "$previous_user" == none ]]; then
    grep -qF default-config "$config_dir/config.yml" || fail 'fresh install did not create the default configuration'
  else
    [[ $(sha256sum "$config_dir/config.yml" | awk '{print $1}') == "$config_hash" ]] || fail "upgrade from ${previous_user} changed configuration"
    [[ $(sha256sum "$config_dir/cert/server.key" | awk '{print $1}') == "$cert_hash" ]] || fail "upgrade from ${previous_user} changed certificate data"
    [[ $(sha256sum "$XRAYR_STATE_DIR/existing.state" | awk '{print $1}') == "$state_hash" ]] || fail "upgrade from ${previous_user} changed state data"
    grep -qF 'start XrayR' "$state/systemctl.log" || fail "upgrade from ${previous_user} did not restart XrayR"
  fi
)

assert_standard_install_flow none
assert_standard_install_flow root
assert_standard_install_flow xrayr

assert_machine_mode_flow() (
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-machine-root.XXXXXX")
  trap 'rm -rf -- "$state"' EXIT
  source "$repo_root/install-machine.sh"
  cur_dir="$repo_root"
  service_file="$state/XrayR.service"
  : > "$state/systemctl.log"
  systemctl(){ printf '%s\n' "$*" >> "$state/systemctl.log"; }
  install_service
  start_service
  assert_service_identity "$service_file"
  local reload_line start_line
  reload_line=$(grep -n '^daemon-reload$' "$state/systemctl.log" | cut -d: -f1)
  start_line=$(grep -n '^start XrayR$' "$state/systemctl.log" | cut -d: -f1)
  [[ -n "$reload_line" && -n "$start_line" && "$reload_line" -lt "$start_line" ]] || fail 'machine mode does not daemon-reload before start'
)
assert_machine_mode_flow

grep -qF 'run_remote_installer https://raw.githubusercontent.com/Mtoly/XrayRPS/main/install.sh' "$repo_root/XrayR.sh" || fail 'management install/update no longer uses the standard installer'
grep -qF 'systemctl daemon-reload' "$repo_root/install.sh" || fail 'standard installer is missing daemon-reload'
grep -qF 'systemctl daemon-reload' "$repo_root/install-machine.sh" || fail 'machine installer is missing daemon-reload'
grep -qF '`XrayR.service` 明确使用 `root:root` 运行' "$repo_root/README.md" || fail 'README does not document root compatibility mode'
grep -qF 'Run the systemd unit as `root:root`' "$repo_root/SECURITY.md" || fail 'SECURITY.md still documents the dedicated account'
grep -qF 'Restore `XrayR.service` to `User=root` and `Group=root`' "$repo_root/CHANGELOG.md" || fail 'CHANGELOG does not record the compatibility rollback'
if grep -qF '专用 `xrayr` 服务账号' "$repo_root/README.md"; then fail 'README still recommends the dedicated account'; fi

run_low_port_check() {
  local runner=()
  if [[ $(id -u) -eq 0 ]]; then
    runner=()
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    runner=(sudo -n)
  else
    echo 'INFO: runtime low-port bind check requires root; static User=root/Group=root check passed'
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo 'INFO: python3 is unavailable; static User=root/Group=root check passed'
    return 0
  fi
  "${runner[@]}" python3 - <<'PY'
import socket
sockets = []
try:
    for port in (80, 443):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", port))
        sock.listen(1)
        sockets.append(sock)
finally:
    for sock in sockets:
        sock.close()
print("low-port bind passed: 80,443")
PY
}
run_low_port_check

echo 'PASS: root service compatibility, install/upgrade transitions, machine mode, preserved data, daemon-reload, and low ports'
