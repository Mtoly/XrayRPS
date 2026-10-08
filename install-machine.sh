#!/bin/bash

set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)
release=""
arch_name=""

install_dir="${XRAYR_INSTALL_DIR:-/usr/local/XrayR}"
config_dir="${XRAYR_CONFIG_DIR:-/etc/XrayR}"
config_file="${config_dir}/config.yml"
service_file="${XRAYR_SERVICE_FILE:-/etc/systemd/system/XrayR.service}"

# Keep this block identical in all three standalone entrypoints.
service_manager=systemd
detect_service_manager() {
    local runtime_root=""
    if [[ "${XRAYR_TEST_MODE:-0}" == 1 ]]; then
        runtime_root="${XRAYR_INIT_ROOT:-}"
    fi
    if [[ -d "${runtime_root}/run/systemd/system" ]] &&
        command -v systemctl >/dev/null 2>&1 &&
        systemctl show --property=Version --value >/dev/null 2>&1; then
        service_manager=systemd
    elif [[ -s "${runtime_root}/run/openrc/softlevel" ]] &&
        command -v rc-service >/dev/null 2>&1 &&
        command -v rc-update >/dev/null 2>&1 &&
        command -v supervise-daemon >/dev/null 2>&1; then
        service_manager=openrc
    else
        echo "Unsupported init environment: requires running systemd or OpenRC (rc-service, rc-update, supervise-daemon)." >&2
        return 1
    fi
    if [[ "$service_manager" == openrc ]]; then
        service_file="${XRAYR_SERVICE_FILE:-/etc/init.d/XrayR}"
    else
        service_file="${XRAYR_SERVICE_FILE:-/etc/systemd/system/XrayR.service}"
    fi
}

service_control() {
    local action="$1"
    shift
    if [[ "$service_manager" == systemd ]]; then
        case "$action" in
            daemon-reload|reset-failed) systemctl "$action" "$@" ;;
            *) systemctl "$action" XrayR "$@" ;;
        esac
        return $?
    fi
    case "$action" in
        start|stop|restart|status) rc-service XrayR "$action" ;;
        is-active) rc-service XrayR status >/dev/null 2>&1 ;;
        enable) rc-update add XrayR default ;;
        disable)
            local enabled_services
            enabled_services=$(rc-update show default) || return 1
            if grep -Eq '^[[:space:]]*XrayR[[:space:]]*\|' <<< "$enabled_services"; then
                rc-update del XrayR default
            else
                return 0
            fi
            ;;
        is-enabled) rc-update show default | grep -E '^[[:space:]]*XrayR[[:space:]]*\|' >/dev/null ;;
        daemon-reload|reset-failed) return 0 ;;
        *) echo "Unsupported OpenRC operation: $action" >&2; return 1 ;;
    esac
}

service_logs() {
    if [[ "$service_manager" == systemd ]]; then
        journalctl -u XrayR.service -e --no-pager -f
    else
        local log_dir="${XRAYR_LOG_DIR:-/var/log/XrayR}"
        if [[ ! -f "$log_dir/output.log" || ! -f "$log_dir/error.log" ]]; then
            echo "OpenRC logs are created on first start: $log_dir" >&2
            return 1
        fi
        tail -n 100 -f "$log_dir/output.log" "$log_dir/error.log"
    fi
}
# End standalone service-manager block.

snapshot_service_state() {
    local snapshot="$1"
    mkdir -p "$snapshot" || return 1
    if [[ -f "$service_file" ]]; then
        cp -p -- "$service_file" "$snapshot/service" || return 1
        if service_control is-active --quiet >/dev/null 2>&1; then
            touch "$snapshot/active" || return 1
        fi
        if service_control is-enabled >/dev/null 2>&1; then
            touch "$snapshot/enabled" || return 1
        fi
    fi
    if [[ -d "$config_dir" ]]; then
        cp -a -- "$config_dir" "$snapshot/config" || return 1
    fi
    return 0
}

restore_service_state() {
    local snapshot="$1"
    if service_control is-enabled >/dev/null 2>&1; then
        service_control disable || return 1
    fi
    if [[ -f "$snapshot/service" ]]; then
        cp -p -- "$snapshot/service" "$service_file" || return 1
    else
        rm -f -- "$service_file" || return 1
    fi
    if [[ -d "$snapshot/config" ]]; then
        rm -rf -- "$config_dir" || return 1
        cp -a -- "$snapshot/config" "$config_dir" || return 1
    else
        rm -rf -- "$config_dir" || return 1
    fi
    service_control daemon-reload || return 1
    if [[ -f "$snapshot/enabled" ]]; then
        service_control enable || return 1
    elif [[ -f "$snapshot/service" ]]; then
        service_control disable || return 1
    else
        service_control disable >/dev/null 2>&1 || true
    fi
    if [[ -f "$snapshot/active" ]]; then
        service_control start || return 1
        service_control is-active --quiet || return 1
    fi
}
management_script="/usr/bin/XrayR"
script_repo="Mtoly/XrayRPS"
release_repo="Mtoly/XrayRP"
raw_branch="main"

api_host=""
machine_id=""
token=""
panel_type="NewV2board"
version="latest"
timeout="30"
discovery_interval="60"
listen_ip="0.0.0.0"
send_ip="0.0.0.0"
enable_ws="true"
ws_endpoint=""
heartbeat_interval="30"
reconnect_backoff="5"
resync_on_reconnect="true"
force="false"
dry_run="false"

usage() {
    cat <<'EOF'
XrayRP Xboard machine-mode installer

Usage:
  install-machine.sh --api-host URL --machine-id ID --token TOKEN [options]

When run in an interactive terminal, any of the required options below that
are not passed on the command line are prompted for instead.

Required:
  --api-host URL              Xboard panel URL, for example https://panel.example.com
  --machine-id ID             MachineID copied from Xboard
  --token TOKEN               Machine token copied from Xboard

Options:
  --panel-type TYPE           Panel type (default: NewV2board)
  --version VERSION           XrayRP release version, or latest (default: latest)
  --timeout SECONDS           API request timeout (default: 30)
  --discovery-interval SEC    Machine node discovery interval (default: 60)
  --listen-ip IP              Controller listen IP (default: 0.0.0.0)
  --send-ip IP                Controller send IP (default: 0.0.0.0)
  --enable-ws                 Enable machine WebSocket config (default)
  --disable-ws                Disable machine WebSocket config
  --ws-endpoint ENDPOINT      Optional WebSocket endpoint
  --heartbeat-interval SEC    WebSocket heartbeat interval (default: 30)
  --reconnect-backoff SEC     WebSocket reconnect backoff (default: 5)
  --resync-on-reconnect BOOL  Resync on WebSocket reconnect: true or false (default: true)
  --force                     Overwrite existing /etc/XrayR/config.yml
  --dry-run                   Print intended actions without installing or writing files
  --help                      Show this help

Interactive example:
  install-machine.sh

Non-interactive example:
  install-machine.sh --api-host URL --machine-id ID --token TOKEN
EOF
}

info() {
    echo -e "${green}$*${plain}"
}

warn() {
    echo -e "${yellow}$*${plain}"
}

die() {
    echo -e "${red}Error:${plain} $*" >&2
    exit 1
}

need_value() {
    local flag="$1"
    local value="${2:-}"
    [[ -n "$value" ]] || die "${flag} requires a value"
}

parse_bool() {
    local flag="$1"
    local value="$2"
    case "$value" in
        true|false)
            printf '%s' "$value"
            ;;
        *)
            die "${flag} must be true or false"
            ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-host)
                shift
                need_value "--api-host" "${1:-}"
                api_host="$1"
                ;;
            --machine-id)
                shift
                need_value "--machine-id" "${1:-}"
                machine_id="$1"
                ;;
            --token)
                shift
                need_value "--token" "${1:-}"
                token="$1"
                ;;
            --panel-type)
                shift
                need_value "--panel-type" "${1:-}"
                panel_type="$1"
                ;;
            --version)
                shift
                need_value "--version" "${1:-}"
                version="$1"
                ;;
            --timeout)
                shift
                need_value "--timeout" "${1:-}"
                timeout="$1"
                ;;
            --discovery-interval)
                shift
                need_value "--discovery-interval" "${1:-}"
                discovery_interval="$1"
                ;;
            --listen-ip)
                shift
                need_value "--listen-ip" "${1:-}"
                listen_ip="$1"
                ;;
            --send-ip)
                shift
                need_value "--send-ip" "${1:-}"
                send_ip="$1"
                ;;
            --enable-ws)
                enable_ws="true"
                ;;
            --disable-ws)
                enable_ws="false"
                ;;
            --ws-endpoint)
                shift
                need_value "--ws-endpoint" "${1:-}"
                ws_endpoint="$1"
                ;;
            --heartbeat-interval)
                shift
                need_value "--heartbeat-interval" "${1:-}"
                heartbeat_interval="$1"
                ;;
            --reconnect-backoff)
                shift
                need_value "--reconnect-backoff" "${1:-}"
                reconnect_backoff="$1"
                ;;
            --resync-on-reconnect)
                shift
                need_value "--resync-on-reconnect" "${1:-}"
                resync_on_reconnect=$(parse_bool "--resync-on-reconnect" "$1")
                ;;
            --force)
                force="true"
                ;;
            --dry-run)
                dry_run="true"
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
}

# Interactive prompt helpers. /dev/tty keeps prompts working when the script
# itself is piped, and makes sure the answers never enter the script's own
# stdin/stdout pipes. When no foreground terminal is available the installer
# stays non-interactive and validate_args reports the missing options.
interactive_available() {
    local stat_line rest pgid tpgid
    local -a stat_fields
    local IFS=$' \t\n'

    [[ -c /dev/tty ]] || return 1
    { true < /dev/tty > /dev/tty; } 2>/dev/null || return 1

    # Reading /dev/tty, which prompt_value does later, sends SIGTTIN and stops
    # the process when its process group is not the terminal's foreground
    # group, and a stopped process never reaches the redirection error. Treat
    # only a foreground process group as interactive. After the leading
    # "pid (comm) " the /proc/self/stat fields are state ppid pgrp session
    # tty_nr tpgid, so the array indexes below are pgrp and tpgid.
    [[ -r /proc/self/stat ]] || return 1
    IFS= read -r stat_line < /proc/self/stat || return 1
    rest=${stat_line##*) }
    read -r -a stat_fields <<< "$rest" || return 1
    pgid=${stat_fields[2]:-}
    tpgid=${stat_fields[5]:-}
    [[ -n "$pgid" && -n "$tpgid" ]] || return 1
    [[ "$tpgid" == "$pgid" ]]
}

prompt_value() {
    local label="$1"
    local varname="$2"
    local hidden="${3:-false}"
    local value=""

    while :; do
        if [[ "$hidden" == "true" ]]; then
            printf '%s: ' "$label" > /dev/tty
            IFS= read -r -s value < /dev/tty || {
                printf '\n' > /dev/tty
                die "Unable to read ${label} from /dev/tty"
            }
            printf '\n' > /dev/tty
        else
            printf '%s: ' "$label" > /dev/tty
            IFS= read -r value < /dev/tty || die "Unable to read ${label} from /dev/tty"
        fi

        [[ -n "$value" ]] && break
        printf 'A value is required for %s.\n' "$label" > /dev/tty
    done

    printf -v "$varname" '%s' "$value"
}

prompt_missing_required() {
    if [[ -n "$api_host" && -n "$machine_id" && -n "$token" ]]; then
        return 0
    fi
    if ! interactive_available; then
        return 0
    fi

    printf 'Machine mode installation requires the following values.\n' > /dev/tty
    [[ -n "$api_host" ]] || prompt_value "API Host" api_host
    [[ -n "$machine_id" ]] || prompt_value "Machine ID" machine_id
    [[ -n "$token" ]] || prompt_value "Machine Token" token true
}

validate_number() {
    local flag="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || die "${flag} must be a positive integer"
    (( value > 0 )) || die "${flag} must be greater than 0"
}

validate_ip() {
    local flag="$1"
    local value="$2"
    local octet
    local -a octets

    if [[ "$value" == *:* ]]; then
        [[ "$value" =~ ^[0-9A-Fa-f:.]+$ ]] || die "${flag} must be a valid IP address"
        return
    fi

    IFS='.' read -r -a octets <<< "$value"
    [[ "${#octets[@]}" -eq 4 ]] || die "${flag} must be a valid IP address"
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && (( octet <= 255 )) || die "${flag} must be a valid IP address"
    done
}

validate_args() {
    [[ -n "$api_host" ]] || die "--api-host is required"
    [[ -n "$machine_id" ]] || die "--machine-id is required"
    [[ -n "$token" ]] || die "--token is required"
    [[ -n "$panel_type" ]] || die "--panel-type cannot be empty"

    api_host="${api_host%/}"
    [[ "$api_host" =~ ^https?:// ]] || die "--api-host must start with http:// or https://"

    validate_number "--machine-id" "$machine_id"
    validate_number "--timeout" "$timeout"
    validate_number "--discovery-interval" "$discovery_interval"
    validate_number "--heartbeat-interval" "$heartbeat_interval"
    validate_number "--reconnect-backoff" "$reconnect_backoff"
    validate_ip "--listen-ip" "$listen_ip"
    validate_ip "--send-ip" "$send_ip"
    resync_on_reconnect=$(parse_bool "--resync-on-reconnect" "$resync_on_reconnect")

    if [[ "$version" != "latest" ]]; then
        local requested_version="$version"
        if ! version=$(normalize_release_version "$requested_version"); then
            die "Invalid release version: ${requested_version}"
        fi
    fi
}

normalize_release_version() {
    local candidate="$1"
    if [[ "$candidate" == v* ]]; then
        [[ "$candidate" =~ ^v[0-9] ]] || return 1
        candidate="${candidate#v}"
    fi
    [[ "$candidate" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || return 1
    printf '%s\n' "$candidate"
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This installer must be run as root"
}

detect_os() {
    if [[ -f /etc/alpine-release ]]; then
        release="alpine"
    elif [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif cat /etc/issue 2>/dev/null | grep -Eqi "debian"; then
        release="debian"
    elif cat /etc/issue 2>/dev/null | grep -Eqi "ubuntu"; then
        release="ubuntu"
    elif cat /etc/issue 2>/dev/null | grep -Eqi "centos|red hat|redhat"; then
        release="centos"
    elif cat /proc/version 2>/dev/null | grep -Eqi "debian"; then
        release="debian"
    elif cat /proc/version 2>/dev/null | grep -Eqi "ubuntu"; then
        release="ubuntu"
    elif cat /proc/version 2>/dev/null | grep -Eqi "centos|red hat|redhat"; then
        release="centos"
    else
        die "Unsupported Linux distribution"
    fi

    local os_version=""
    local major_version=""
    if [[ -f /etc/os-release ]]; then
        os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
    fi
    if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
        os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
    fi

    major_version="${os_version%%.*}"
    if [[ "$major_version" =~ ^[0-9]+$ ]]; then
        if [[ "$release" == "centos" && "$major_version" -le 6 ]]; then
            die "Please use CentOS 7 or later"
        elif [[ "$release" == "ubuntu" && "$major_version" -lt 16 ]]; then
            die "Please use Ubuntu 16 or later"
        elif [[ "$release" == "debian" && "$major_version" -lt 8 ]]; then
            die "Please use Debian 8 or later"
        fi
    fi
}

detect_arch() {
    local detected_arch
    detected_arch=$(arch 2>/dev/null || uname -m)

    if [[ "$detected_arch" == "x86_64" || "$detected_arch" == "x64" || "$detected_arch" == "amd64" ]]; then
        arch_name="64"
    elif [[ "$detected_arch" == "aarch64" || "$detected_arch" == "arm64" ]]; then
        arch_name="arm64-v8a"
    elif [[ "$detected_arch" == "s390x" ]]; then
        arch_name="s390x"
    else
        arch_name="64"
        warn "Failed to detect architecture, using default architecture: ${arch_name}"
    fi

    if [[ "$(getconf WORD_BIT 2>/dev/null || echo 32)" != "32" ]] && [[ "$(getconf LONG_BIT 2>/dev/null || echo 32)" != "64" ]]; then
        die "32-bit systems are not supported"
    fi
}

require_service_manager() {
    [[ "$(uname -s)" == "Linux" ]] || die "This installer supports Linux only"
    detect_service_manager || exit 1
}

install_base() {
    info "Installing required tools: curl, wget, unzip, tar, socat"
    if [[ "$release" == "centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar socat -y
    elif [[ "$release" == "alpine" ]]; then
        apk add --no-cache wget curl unzip tar socat
    else
        apt update -y
        DEBIAN_FRONTEND=noninteractive apt install wget curl unzip tar socat -y
    fi
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

yaml_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

read_yaml_section_scalar() {
    local source_file="$1"
    local section="$2"
    local key="$3"

    awk -v section="$section" -v key="$key" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }

        function scalar(value, quote) {
            value = trim(value)
            quote = substr(value, 1, 1)
            if (quote == "\"" || quote == "\047") {
                value = substr(value, 2)
                sub(quote "[[:space:]]*(#.*)?$", "", value)
                return value
            }
            sub(/[[:space:]]+#.*$/, "", value)
            return trim(value)
        }

        $0 ~ ("^" section "[[:space:]]*:") {
            in_section = 1
            next
        }

        in_section && $0 ~ /^[^[:space:]#]/ {
            exit
        }

        in_section {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line ~ ("^" key "[[:space:]]*:")) {
                sub(("^" key "[[:space:]]*:"), "", line)
                print scalar(line)
                found = 1
                exit
            }
        }

        END {
            if (!found) {
                exit 1
            }
        }
    ' "$source_file"
}

validate_machine() {
    local endpoint="${api_host}/api/v2/server/machine/nodes"
    local payload
    local response_file
    local http_code

    payload=$(printf '{"machine_id":%s,"token":"%s"}' "$machine_id" "$(json_escape "$token")")
    response_file=$(mktemp)

    info "Validating MachineID and token with Xboard"
    if ! http_code=$(curl -sS -m "$timeout" -o "$response_file" -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -X POST \
        --data-binary "$payload" \
        "$endpoint"); then
        rm -f "$response_file"
        die "Machine validation request failed. Check --api-host and network connectivity"
    fi

    rm -f "$response_file"

    if [[ ! "$http_code" =~ ^2 ]]; then
        die "Machine validation failed with HTTP ${http_code}. Check --api-host, --machine-id, and token"
    fi
}

download_https() {
    local url="$1"
    local destination="$2"

    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        --connect-timeout "$timeout" --max-time "$timeout" \
        -o "$destination" "$url"
}

resolve_version() {
    local metadata_file

    if [[ "$version" == "latest" ]]; then
        metadata_file=$(mktemp "${TMPDIR:-/tmp}/xrayr-release-metadata.XXXXXX")
        if ! download_https "https://api.github.com/repos/${release_repo}/releases/latest" "$metadata_file"; then
            rm -f -- "$metadata_file"
            die "Failed to detect latest XrayRP release version"
        fi
        version=$(grep '"tag_name":' "$metadata_file" | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1)
        rm -f -- "$metadata_file"
        [[ -n "$version" ]] || die "Failed to detect latest XrayRP release version"
    fi
    [[ "$version" =~ ^v?[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "Invalid release version: ${version}"
}

verify_release_checksum() {
    local release_dir="$1"
    local artifact_name="$2"
    local checksum_file="${release_dir}/SHA256SUMS"
    local expected

    [[ -f "$checksum_file" ]] || return 1
    expected=$(awk -v artifact="$artifact_name" '$2 == artifact || $2 == "*" artifact {print $1; exit}' "$checksum_file")
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    [[ -f "${release_dir}/${artifact_name}" ]] || return 1
    printf '%s  %s\n' "$expected" "${release_dir}/${artifact_name}" | sha256sum -c - >/dev/null
}

ensure_service_permissions() {
    local state_dir="${XRAYR_STATE_DIR:-/var/lib/xrayr}"
    local runtime_dir="${XRAYR_INSTALL_DIR:-/usr/local/XrayR}"
    local settings_dir="${XRAYR_CONFIG_DIR:-/etc/XrayR}"

    install -d -o root -g root -m 0750 "$state_dir" "$settings_dir" || return 1
    if [[ -d "$runtime_dir" ]]; then
        chown -R root:root "$runtime_dir" || return 1
        find "$runtime_dir" -type d -exec chmod 0750 {} + || return 1
        find "$runtime_dir" -type f -exec chmod 0640 {} + || return 1
        [[ ! -f "$runtime_dir/XrayR" ]] || chmod 0750 "$runtime_dir/XrayR" || return 1
    fi
    chown -R root:root "$settings_dir" || return 1
    chown -R root:root "$state_dir" || return 1
    find "$settings_dir" -type d -exec chmod 0750 {} + || return 1
    find "$settings_dir" -type f -exec chmod 0640 {} + || return 1
    find "$state_dir" -type d -exec chmod 0750 {} + || return 1
    find "$state_dir" -type f -exec chmod 0640 {} + || return 1
}

install_service() {
    local service_asset=XrayR.service service_mode=0644
    if [[ "$service_manager" == openrc ]]; then
        service_asset=XrayR.openrc
        service_mode=0755
    fi
    local service_source="${cur_dir}/${service_asset}"

    if [[ -f "$service_source" ]]; then
        install -m "$service_mode" "$service_source" "$service_file"
        return
    fi

    local service_tmp
    service_tmp=$(mktemp "${TMPDIR:-/tmp}/xrayr-service.XXXXXX")
    if ! curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        -o "$service_tmp" "https://raw.githubusercontent.com/${script_repo}/${raw_branch}/${service_asset}"; then
        rm -f -- "$service_tmp"
        die "Failed to download XrayR ${service_manager} service file"
    fi
    install -m "$service_mode" "$service_tmp" "$service_file"
    rm -f -- "$service_tmp"
}

install_management_script() {
    if [[ -f "${cur_dir}/XrayR.sh" ]]; then
        cp -f "${cur_dir}/XrayR.sh" "$management_script"
    else
        curl --fail --silent --show-error --location \
            --proto '=https' --tlsv1.2 \
            -o "$management_script" "https://raw.githubusercontent.com/${script_repo}/${raw_branch}/XrayR.sh"
    fi
    chmod +x "$management_script"
    ln -sf "$management_script" /usr/bin/xrayr
    chmod +x /usr/bin/xrayr
}

copy_default_config_file() {
    local source_name="$1"
    local target_name="${config_dir}/${source_name}"

    if [[ -f "${install_dir}/${source_name}" && ! -f "$target_name" ]]; then
        cp "${install_dir}/${source_name}" "$target_name"
    fi
}

rollback_installation() {
    [[ "$transaction_active" == "true" ]] || return 0
    if [[ -f "$service_file" ]] && ! service_control stop; then
        echo "Rollback failed to stop XrayR; recovery files remain at $transaction_dir." >&2
        transaction_active=false
        return 1
    fi
    if [[ "$transaction_had_previous" == true && ! -d "$transaction_backup" ]]; then
        echo "Rollback failed: original binary backup missing at $transaction_backup." >&2
        transaction_active=false
        return 1
    fi
    if ! rm -rf -- "$install_dir" ||
        { [[ "$transaction_had_previous" == true ]] && ! mv -- "$transaction_backup" "$install_dir"; }; then
        echo "Rollback failed to restore binary; recovery files remain at $transaction_backup." >&2
        transaction_active=false
        return 1
    fi
    if ! restore_service_state "$transaction_dir/service-state"; then
        echo "Rollback incomplete; recovery files remain at $transaction_dir." >&2
        transaction_active=false
        return 1
    fi
    rm -rf -- "$transaction_dir"
    transaction_active="false"
}

commit_installation() {
    [[ "$transaction_active" == "true" ]] || return 0
    rm -rf -- "$transaction_dir"
    transaction_active="false"
}

download_and_install_release() {
    local download_url
    local artifact_name
    local archive_file
    local staged_install

    resolve_version
    artifact_name="XrayR-linux-${arch_name}.zip"
    download_url="https://github.com/${release_repo}/releases/download/${version}/${artifact_name}"

    info "Installing XrayRP ${version} (${arch_name})"
    transaction_dir=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-install.XXXXXX")
    archive_file="${transaction_dir}/${artifact_name}"
    staged_install="${transaction_dir}/new"
    transaction_backup="${transaction_dir}/previous"
    mkdir -p "$staged_install"
    if ! snapshot_service_state "$transaction_dir/service-state"; then
        rm -rf -- "$transaction_dir"
        die "Failed to snapshot the previous installation"
    fi

    if ! download_https "$download_url" "$archive_file"; then
        rm -rf -- "$transaction_dir"
        die "Failed to download XrayRP release"
    fi
    if ! download_https "https://github.com/${release_repo}/releases/download/${version}/SHA256SUMS" "${transaction_dir}/SHA256SUMS"; then
        rm -rf -- "$transaction_dir"
        die "Failed to download XrayRP release checksums"
    fi
    if ! verify_release_checksum "$transaction_dir" "$artifact_name"; then
        rm -rf -- "$transaction_dir"
        die "Release checksum verification failed for ${artifact_name}"
    fi
    if ! unzip -oq "$archive_file" -d "$staged_install"; then
        rm -rf -- "$transaction_dir"
        die "Failed to extract XrayRP release"
    fi
    [[ -x "${staged_install}/XrayR" ]] || {
        rm -rf -- "$transaction_dir"
        die "Release archive does not contain an executable XrayR binary"
    }

    transaction_had_previous="false"
    if [[ -f "$transaction_dir/service-state/active" ]] && ! service_control stop; then
        rm -rf -- "$transaction_dir"
        die "Failed to stop XrayR before upgrade; current installation preserved"
    fi
    if [[ -d "$install_dir" ]]; then
        if ! mv -- "$install_dir" "$transaction_backup"; then
            restore_service_state "$transaction_dir/service-state" ||
                die "Failed to resume the previous service; recovery files remain at $transaction_dir"
            rm -rf -- "$transaction_dir"
            die "Failed to back up the current installation"
        fi
        transaction_had_previous="true"
    fi
    if ! mv -- "$staged_install" "$install_dir"; then
        if [[ "$transaction_had_previous" == true ]] && ! mv -- "$transaction_backup" "$install_dir"; then
            die "Activation and rollback failed; original binary remains at $transaction_backup"
        fi
        restore_service_state "$transaction_dir/service-state" ||
            die "Failed to resume the previous service; recovery files remain at $transaction_dir"
        rm -rf -- "$transaction_dir"
        die "Failed to activate the staged XrayRP release"
    fi
    transaction_active="true"
    trap rollback_installation EXIT
    cd "$install_dir"
    chmod +x XrayR

    mkdir -p "$config_dir"
    [[ -f geoip.dat ]] && cp -f geoip.dat "${config_dir}/"
    [[ -f geosite.dat ]] && cp -f geosite.dat "${config_dir}/"
    copy_default_config_file dns.json
    copy_default_config_file route.json
    copy_default_config_file custom_outbound.json
    copy_default_config_file custom_inbound.json
    copy_default_config_file rulelist
}

write_machine_config() {
    local tmp_config
    local observability_enable="true"
    local observability_listen="127.0.0.1:10085"
    local observability_stale_after="180"
    local preserved_value
    local escaped_api_host
    local escaped_observability_listen
    local escaped_panel_type
    local escaped_token
    local escaped_listen_ip
    local escaped_send_ip
    local escaped_ws_endpoint

    mkdir -p "$config_dir"

    if [[ -f "$config_file" ]]; then
        if preserved_value=$(read_yaml_section_scalar "$config_file" "Observability" "Enable"); then
            case "${preserved_value,,}" in
                true|false)
                    observability_enable="${preserved_value,,}"
                    ;;
            esac
        fi
        if preserved_value=$(read_yaml_section_scalar "$config_file" "Observability" "Listen"); then
            observability_listen="$preserved_value"
        fi
        if preserved_value=$(read_yaml_section_scalar "$config_file" "Observability" "ReadinessStaleAfter"); then
            if [[ "$preserved_value" =~ ^[0-9]+$ ]]; then
                observability_stale_after="$preserved_value"
            fi
        fi
    fi

    tmp_config=$(mktemp "${config_file}.tmp.XXXXXX")

    escaped_api_host=$(yaml_escape "$api_host")
    escaped_observability_listen=$(yaml_escape "$observability_listen")
    escaped_panel_type=$(yaml_escape "$panel_type")
    escaped_token=$(yaml_escape "$token")
    escaped_listen_ip=$(yaml_escape "$listen_ip")
    escaped_send_ip=$(yaml_escape "$send_ip")
    escaped_ws_endpoint=$(yaml_escape "$ws_endpoint")

    {
        cat <<EOF
Log:
  Level: warning
  AccessPath:
  ErrorPath:
  ShowErrorDetails: false

DnsConfigPath:
RouteConfigPath:
InboundConfigPath:
OutboundConfigPath:

ConnectionConfig:
  Handshake: 4
  ConnIdle: 30
  UplinkOnly: 2
  DownlinkOnly: 4
  BufferSize: 4

Observability:
  Enable: ${observability_enable}
  Listen: "${escaped_observability_listen}"
  ReadinessStaleAfter: ${observability_stale_after}

MachineConfig:
  Enable: true
  PanelType: "${escaped_panel_type}"
  ApiHost: "${escaped_api_host}"
  MachineID: ${machine_id}
  Token: "${escaped_token}"
  Timeout: ${timeout}
  DiscoveryInterval: ${discovery_interval}
  ControllerConfig:
    ListenIP: "${escaped_listen_ip}"
    SendIP: "${escaped_send_ip}"
    UpdatePeriodic: ${discovery_interval}
    WebSocketConfig:
      Enable: ${enable_ws}
EOF
        if [[ -n "$escaped_ws_endpoint" ]]; then
            echo "      Endpoint: \"${escaped_ws_endpoint}\""
        else
            echo "      Endpoint:"
        fi
        cat <<EOF
      HeartbeatInterval: ${heartbeat_interval}
      ReconnectBackoff: ${reconnect_backoff}
      ResyncOnReconnect: ${resync_on_reconnect}
EOF
    } > "$tmp_config"

    chmod 600 "$tmp_config"
    if [[ -f "$config_file" && "$force" != "true" ]]; then
        rm -f "$tmp_config"
        die "${config_file} already exists. Re-run with --force to overwrite it"
    fi
    mv -f "$tmp_config" "$config_file"
}

start_service() {
    service_control daemon-reload || return 1
    service_control stop >/dev/null 2>&1 || true
    service_control enable || return 1
    service_control start || return 1
    service_control is-active --quiet
}

print_next_steps() {
    echo ""
    echo "Useful commands:"
    echo "XrayR status"
    echo "XrayR log"
}

print_dry_run() {
    detect_arch

    echo "Dry run: no files will be written and no services will be changed."
    echo "Would verify root privileges and a running systemd or OpenRC environment before installing."
    echo "Would install required tools: curl, wget, unzip, tar, socat."
    if [[ "$version" == "latest" ]]; then
        echo "Would resolve the latest release from https://api.github.com/repos/${release_repo}/releases/latest."
        echo "Would download XrayR-linux-${arch_name}.zip from ${release_repo} releases."
    else
        echo "Would download https://github.com/${release_repo}/releases/download/${version}/XrayR-linux-${arch_name}.zip."
    fi
    echo "Would install XrayRP files to ${install_dir} and data files to ${config_dir}."
    echo "Would install ${service_file} using /etc/XrayR/config.yml."
    echo "Would install the XrayR management script to ${management_script}."
    echo "Would validate MachineID ${machine_id} by POSTing to ${api_host}/api/v2/server/machine/nodes with the token redacted."
    if [[ -f "$config_file" && "$force" != "true" ]]; then
        echo "Would refuse to overwrite existing ${config_file} without --force."
    elif [[ "$force" == "true" ]]; then
        echo "Would overwrite ${config_file} because --force was passed."
    else
        echo "Would create ${config_file}."
    fi
    echo "Generated config would enable MachineConfig and would not contain static Nodes."
    echo "Config values: PanelType=${panel_type}, ApiHost=${api_host}, MachineID=${machine_id}, Token=[redacted], WebSocket=${enable_ws}."
    echo "Would chmod 600 ${config_file}."
    echo "Would enable and start XrayR after successful validation."
    print_next_steps
}

main() {
    parse_args "$@"
    prompt_missing_required
    validate_args

    if [[ "$dry_run" == "true" ]]; then
        print_dry_run
        exit 0
    fi

    require_root
    require_service_manager
    detect_os
    detect_arch

    if [[ -f "$config_file" && "$force" != "true" ]]; then
        die "${config_file} already exists. Re-run with --force to overwrite it"
    fi

    install_base
    validate_machine
    download_and_install_release
    install_service
    install_management_script
    write_machine_config
    if ! ensure_service_permissions; then
        rollback_installation
        die "Failed to set root-owned XrayR service permissions"
    fi
    if ! start_service; then
        rollback_installation
        die "XrayR failed to start; rollback was attempted (see preceding errors if incomplete)"
    fi
    commit_installation
    trap - EXIT

    info "XrayRP machine mode installation completed"
    print_next_steps
}

# BASH_SOURCE is unset when the script is fed through stdin (for example
# "curl ... | bash"); fall back to $0 so that those runs still install.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
