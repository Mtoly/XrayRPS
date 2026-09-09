#!/bin/bash

set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)
release=""
arch_name=""

install_dir="/usr/local/XrayR"
config_dir="/etc/XrayR"
config_file="${config_dir}/config.yml"
service_file="/etc/systemd/system/XrayR.service"
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
        [[ "$version" == v* ]] || version="v${version}"
        [[ "$version" =~ ^v?[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "Invalid release version: ${version}"
    fi
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This installer must be run as root"
}

detect_os() {
    if [[ -f /etc/redhat-release ]]; then
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

require_systemd() {
    [[ "$(uname -s)" == "Linux" ]] || die "This installer supports Linux systemd only"
    command -v systemctl >/dev/null 2>&1 || die "systemctl was not found; this installer supports systemd only"
}

install_base() {
    info "Installing required tools: curl, wget, unzip, tar, socat"
    if [[ "$release" == "centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar socat -y
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

ensure_service_account() {
    if ! getent passwd xrayr >/dev/null 2>&1; then
        useradd --system --home-dir /var/lib/xrayr --create-home \
            --shell /usr/sbin/nologin --user-group xrayr
    fi
    install -d -o xrayr -g xrayr -m 0750 /var/lib/xrayr
}

install_service() {
    local service_source="${cur_dir}/XrayR.service"

    if [[ -f "$service_source" ]]; then
        install -m 0644 "$service_source" "$service_file"
        return
    fi

    local service_tmp
    service_tmp=$(mktemp "${TMPDIR:-/tmp}/xrayr-service.XXXXXX")
    if ! curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        -o "$service_tmp" "https://raw.githubusercontent.com/${script_repo}/${raw_branch}/XrayR.service"; then
        rm -f -- "$service_tmp"
        die "Failed to download XrayR systemd service file"
    fi
    install -m 0644 "$service_tmp" "$service_file"
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
    systemctl stop XrayR >/dev/null 2>&1 || true
    rm -rf -- "$install_dir"
    if [[ "$transaction_had_previous" == "true" && -d "$transaction_backup" ]]; then
        mv -- "$transaction_backup" "$install_dir"
        systemctl start XrayR >/dev/null 2>&1 || true
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
    if [[ -d "$install_dir" ]]; then
        mv -- "$install_dir" "$transaction_backup"
        transaction_had_previous="true"
    fi
    if ! mv -- "$staged_install" "$install_dir"; then
        [[ "$transaction_had_previous" == "true" ]] && mv -- "$transaction_backup" "$install_dir"
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
    systemctl daemon-reload
    systemctl stop XrayR >/dev/null 2>&1 || true
    systemctl enable XrayR
    systemctl start XrayR
}

print_next_steps() {
    echo ""
    echo "Useful commands:"
    echo "systemctl status XrayR"
    echo "journalctl -u XrayR -f"
    echo "XrayR log"
}

print_dry_run() {
    detect_arch

    echo "Dry run: no files will be written and no services will be changed."
    echo "Would verify root privileges and Linux systemd before installing."
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
    validate_args

    if [[ "$dry_run" == "true" ]]; then
        print_dry_run
        exit 0
    fi

    require_root
    require_systemd
    detect_os
    detect_arch

    if [[ -f "$config_file" && "$force" != "true" ]]; then
        die "${config_file} already exists. Re-run with --force to overwrite it"
    fi

    install_base
    validate_machine
    download_and_install_release
    ensure_service_account
    install_service
    install_management_script
    write_machine_config
    chown -R xrayr:xrayr "$install_dir" "$config_dir"
    if ! start_service; then
        rollback_installation
        die "XrayR failed to start; the previous installation was restored"
    fi
    commit_installation
    trap - EXIT

    info "XrayRP machine mode installation completed"
    print_next_steps
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
