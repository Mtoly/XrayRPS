#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail(){ echo "FAIL: $*" >&2; exit 1; }

run_account_cases() (
  local installer="$1"
  XRAYR_TEST_MODE=1 source "$installer"
  declare -F ensure_service_account >/dev/null || fail "$installer does not expose ensure_service_account"

  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-account-test.XXXXXX")
  trap 'rm -rf -- "$state"' EXIT
  export XRAYR_SERVICE_HOME="$state/home"
  export XRAYR_INSTALL_DIR="$state/install"
  export XRAYR_CONFIG_DIR="$state/config"
  mkdir -p "$XRAYR_INSTALL_DIR" "$XRAYR_CONFIG_DIR"
  printf binary > "$XRAYR_INSTALL_DIR/XrayR"
  chmod 0755 "$XRAYR_INSTALL_DIR/XrayR"
  printf config > "$XRAYR_CONFIG_DIR/config.yml"
  mkdir -p "$XRAYR_CONFIG_DIR/cert"
  printf private-key > "$XRAYR_CONFIG_DIR/cert/server.key"
  : > "$state/users"
  : > "$state/groups"
  : > "$state/commands"

  getent(){
    case "$1" in
      passwd) grep -qxF "$2" "$state/users" 2>/dev/null ;;
      group) grep -qxF "$2" "$state/groups" 2>/dev/null ;;
      *) return 2 ;;
    esac
  }
  groupadd(){
    printf 'groupadd %s\n' "$*" >> "$state/commands"
    [[ "${FORCE_SHADOW_FAIL:-0}" != 1 && "${FAIL_GROUP_CREATE:-0}" != 1 ]] || return 73
    printf '%s\n' "${@: -1}" >> "$state/groups"
  }
  addgroup(){
    if [[ "${1:-}" == --help ]]; then
      [[ "${ACCOUNT_BACKEND:-debian}" == alpine ]] && echo 'BusyBox addgroup'
      return 0
    fi
    printf 'addgroup %s\n' "$*" >> "$state/commands"
    [[ "${FAIL_GROUP_CREATE:-0}" != 1 ]] || return 73
    printf '%s\n' "${@: -1}" >> "$state/groups"
  }
  useradd(){
    printf 'useradd %s\n' "$*" >> "$state/commands"
    [[ "${FORCE_SHADOW_FAIL:-0}" != 1 && "${FAIL_USER_CREATE:-0}" != 1 ]] || return 74
    printf '%s\n' "${@: -1}" >> "$state/users"
  }
  adduser(){
    if [[ "${1:-}" == --help ]]; then
      [[ "${ACCOUNT_BACKEND:-debian}" == alpine ]] && echo 'BusyBox adduser'
      return 0
    fi
    printf 'adduser %s\n' "$*" >> "$state/commands"
    [[ "${FAIL_USER_CREATE:-0}" != 1 ]] || return 74
    printf '%s\n' "${@: -1}" >> "$state/users"
  }
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

  reset_state(){
    : > "$state/users"
    : > "$state/groups"
    : > "$state/commands"
    unset FAIL_GROUP_CREATE FAIL_USER_CREATE FORCE_SHADOW_FAIL ACCOUNT_BACKEND
  }
  assert_user(){ getent passwd xrayr || fail "$installer did not create xrayr user ($1)"; }
  assert_group(){ getent group xrayr || fail "$installer did not create xrayr group ($1)"; }
  simulate_systemd_user_step(){
    getent passwd xrayr >/dev/null 2>&1 && getent group xrayr >/dev/null 2>&1 && return 0
    return 217
  }

  reset_state
  set +e
  simulate_systemd_user_step
  [[ $? -eq 217 ]] || fail "$installer fixture did not reproduce status=217/USER"
  set -e
  ensure_service_account
  simulate_systemd_user_step || fail "$installer still reproduces status=217/USER after provisioning"
  assert_user fresh-install
  assert_group fresh-install
  grep -qF 'groupadd --system xrayr' "$state/commands" || fail "$installer did not use groupadd for shadow-utils systems"
  grep -qF 'useradd --system --gid xrayr --home-dir' "$state/commands" || fail "$installer did not use compatible useradd arguments"

  reset_state
  ensure_service_account
  assert_user root-service-upgrade
  assert_group root-service-upgrade

  reset_state
  printf 'xrayr\n' > "$state/users"
  printf 'xrayr\n' > "$state/groups"
  ensure_service_account
  ensure_service_account
  [[ $(wc -l < "$state/users") -eq 1 ]] || fail "$installer duplicated an existing user"
  [[ $(wc -l < "$state/groups") -eq 1 ]] || fail "$installer duplicated an existing group"
  ! grep -Eq '^(groupadd|addgroup|useradd|adduser) ' "$state/commands" || fail "$installer recreated an existing account"

  reset_state
  printf 'xrayr\n' > "$state/users"
  ensure_service_account
  assert_group user-only-state
  [[ $(wc -l < "$state/users") -eq 1 ]] || fail "$installer duplicated user in user-only state"

  reset_state
  printf 'xrayr\n' > "$state/groups"
  ensure_service_account
  assert_user group-only-state
  [[ $(wc -l < "$state/groups") -eq 1 ]] || fail "$installer duplicated group in group-only state"

  reset_state
  export FAIL_GROUP_CREATE=1
  if ensure_service_account >/dev/null 2>&1; then fail "$installer accepted group creation failure"; fi
  unset FAIL_GROUP_CREATE

  reset_state
  export FAIL_USER_CREATE=1
  if ensure_service_account >/dev/null 2>&1; then fail "$installer accepted user creation failure"; fi
  unset FAIL_USER_CREATE

  reset_state
  export FORCE_SHADOW_FAIL=1 ACCOUNT_BACKEND=debian
  ensure_service_account
  assert_user debian-adduser
  assert_group debian-addgroup
  grep -qF 'addgroup --system xrayr' "$state/commands" || fail "$installer did not use Debian addgroup syntax"
  grep -qF 'adduser --system --ingroup xrayr --home' "$state/commands" || fail "$installer did not use Debian adduser syntax"

  reset_state
  export FORCE_SHADOW_FAIL=1 ACCOUNT_BACKEND=alpine
  ensure_service_account
  assert_user alpine-adduser
  assert_group alpine-addgroup
  grep -qF 'addgroup -S xrayr' "$state/commands" || fail "$installer did not use Alpine addgroup syntax"
  grep -qF 'adduser -S -D -H -h' "$state/commands" || fail "$installer did not use Alpine adduser syntax"

  ensure_service_permissions
  [[ -d "$XRAYR_SERVICE_HOME" ]] || fail "$installer did not create service home"
  [[ -x "$XRAYR_INSTALL_DIR/XrayR" ]] || fail "$installer made the binary non-executable"
  [[ $(stat -c %a "$XRAYR_SERVICE_HOME") == 750 ]] || fail "$installer service home mode is not 0750"
  [[ $(stat -c %a "$XRAYR_INSTALL_DIR") == 750 ]] || fail "$installer runtime directory mode is not 0750"
  [[ $(stat -c %a "$XRAYR_INSTALL_DIR/XrayR") == 750 ]] || fail "$installer binary mode is not 0750"
  [[ $(stat -c %a "$XRAYR_CONFIG_DIR") == 750 ]] || fail "$installer config directory mode is not 0750"
  [[ $(stat -c %a "$XRAYR_CONFIG_DIR/config.yml") == 640 ]] || fail "$installer config file mode is not 0640"
  [[ $(stat -c %a "$XRAYR_CONFIG_DIR/cert") == 750 ]] || fail "$installer certificate directory mode is not 0750"
  [[ $(stat -c %a "$XRAYR_CONFIG_DIR/cert/server.key") == 640 ]] || fail "$installer certificate file mode is not 0640"
  grep -qF "chown -R root:xrayr $XRAYR_INSTALL_DIR" "$state/commands" || fail "$installer runtime ownership is not root:xrayr"
  grep -qF "chown -R xrayr:xrayr $XRAYR_CONFIG_DIR" "$state/commands" || fail "$installer config ownership is not xrayr:xrayr"
)

assert_machine_account_failure_stops_install() (
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-machine-stop-test.XXXXXX")
  trap 'rm -rf -- "$state"' EXIT
  source "$repo_root/install-machine.sh"
  config_file="$state/config.yml"
  transaction_active="true"
  : > "$state/calls"
  parse_args(){ :; }
  validate_args(){ :; }
  require_root(){ :; }
  require_systemd(){ :; }
  detect_os(){ :; }
  detect_arch(){ :; }
  install_base(){ :; }
  validate_machine(){ :; }
  download_and_install_release(){ echo download >> "$state/calls"; }
  ensure_service_account(){ echo account >> "$state/calls"; return 1; }
  rollback_installation(){ echo rollback >> "$state/calls"; transaction_active=false; }
  install_service(){ echo service >> "$state/calls"; }
  start_service(){ echo start >> "$state/calls"; }
  set +e
  ( main ) >"$state/output" 2>&1
  local rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail 'install-machine.sh accepted service account creation failure'
  grep -qF rollback "$state/calls" || fail 'install-machine.sh did not roll back after account failure'
  ! grep -qF service "$state/calls" || fail 'install-machine.sh installed the service after account failure'
  ! grep -qF start "$state/calls" || fail 'install-machine.sh started the service after account failure'
)

assert_legacy_account_failure_stops_install() (
  local state
  state=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-legacy-stop-test.XXXXXX")
  trap 'rm -rf -- "$state"' EXIT
  XRAYR_TEST_MODE=1 source "$repo_root/install.sh"
  install_dir="$state/install"
  config_dir="$state/config"
  service_file="$state/XrayR.service"
  arch=64
  mkdir -p "$install_dir" "$config_dir"
  printf old > "$install_dir/XrayR"
  : > "$state/calls"
  check_status(){ return 1; }
  validate_release_version(){ return 0; }
  download_release_artifact(){ printf archive > "$3"; }
  unzip(){
    local destination=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -d ]]; then destination="$2"; shift 2; else shift; fi
    done
    printf new > "$destination/XrayR"
    chmod +x "$destination/XrayR"
  }
  ensure_service_account(){ echo account >> "$state/calls"; return 1; }
  rollback_transaction(){ echo rollback >> "$state/calls"; }
  systemctl(){ echo "systemctl $*" >> "$state/calls"; }
  set +e
  ( install_XrayR v0.9.2 ) >"$state/output" 2>&1
  local rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail 'install.sh accepted service account creation failure'
  grep -qF rollback "$state/calls" || fail 'install.sh did not roll back after account failure'
  [[ ! -e "$service_file" ]] || fail 'install.sh wrote the service after account failure'
  ! grep -qF systemctl "$state/calls" || fail 'install.sh called systemctl after account failure'
)

for installer in "$repo_root/install.sh" "$repo_root/install-machine.sh"; do
  grep -q '^ensure_service_account()' "$installer" || fail "$installer is missing ensure_service_account"
  grep -q '^ensure_service_permissions()' "$installer" || fail "$installer is missing ensure_service_permissions"
  run_account_cases "$installer"
done

assert_machine_account_failure_stops_install
assert_legacy_account_failure_stops_install

installer="$repo_root/install.sh"
account_line=$(grep -n 'ensure_service_account' "$installer" | tail -n1 | cut -d: -f1)
service_line=$(grep -n 'install -m 0*644 .*service' "$installer" | tail -n1 | cut -d: -f1)
reload_line=$(grep -n 'systemctl daemon-reload' "$installer" | tail -n1 | cut -d: -f1)
start_line=$(grep -n 'systemctl start XrayR' "$installer" | tail -n1 | cut -d: -f1)
(( account_line < service_line && service_line < reload_line && reload_line < start_line )) || fail 'install.sh account/service/reload/start ordering is unsafe'

installer="$repo_root/install-machine.sh"
account_line=$(grep -n 'ensure_service_account' "$installer" | tail -n1 | cut -d: -f1)
service_line=$(grep -n '^[[:space:]]*install_service[[:space:]]*$' "$installer" | tail -n1 | cut -d: -f1)
start_call_line=$(grep -n 'start_service' "$installer" | tail -n1 | cut -d: -f1)
reload_line=$(grep -n 'systemctl daemon-reload' "$installer" | tail -n1 | cut -d: -f1)
start_line=$(grep -n 'systemctl start XrayR' "$installer" | tail -n1 | cut -d: -f1)
(( account_line < service_line && service_line < start_call_line )) || fail 'install-machine.sh account/service/start call ordering is unsafe'
(( reload_line < start_line )) || fail 'install-machine.sh does not reload systemd before starting XrayR'

grep -qF 'User=xrayr' "$repo_root/XrayR.service" || fail 'service user changed unexpectedly'
grep -qF 'Group=xrayr' "$repo_root/XrayR.service" || fail 'service group changed unexpectedly'
for installer in "$repo_root/install.sh" "$repo_root/install-machine.sh"; do
  grep -qF '/etc/alpine-release' "$installer" || fail "$installer does not detect Alpine"
  grep -qF 'apk add --no-cache' "$installer" || fail "$installer does not install Alpine dependencies with apk"
done
grep -qF 'status=217/USER' "$repo_root/README.md" || fail 'README troubleshooting is missing status=217/USER recovery'
grep -qF 'Provision and verify the `xrayr` system user and group' "$repo_root/CHANGELOG.md" || fail 'CHANGELOG service-account fix is missing'

echo 'PASS: service account creation, repair, distro compatibility, permissions, failure handling, and status=217/USER regression'
