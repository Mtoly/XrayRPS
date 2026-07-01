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
    resync_on_reconnect=$(parse_bool "--resync-on-reconnect" "$resync_on_reconnect")

    [[ "$version" == "latest" || "$version" == v* ]] || version="v${version}"
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

resolve_version() {
    if [[ "$version" == "latest" ]]; then
        version=$(curl -fsSL "https://api.github.com/repos/${release_repo}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
        [[ -n "$version" ]] || die "Failed to detect latest XrayRP release version"
    fi
}

install_service() {
    cat > "$service_file" <<'EOF'
[Unit]
Description=XrayR Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/XrayR/
ExecStart=/usr/local/XrayR/XrayR --config /etc/XrayR/config.yml
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

install_management_script() {
    if [[ -f "${cur_dir}/XrayR.sh" ]]; then
        cp -f "${cur_dir}/XrayR.sh" "$management_script"
    else
        curl -fLsS -o "$management_script" "https://raw.githubusercontent.com/${script_repo}/${raw_branch}/XrayR.sh"
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

download_and_install_release() {
    local download_url

    resolve_version
    download_url="https://github.com/${release_repo}/releases/download/${version}/XrayR-linux-${arch_name}.zip"

    info "Installing XrayRP ${version} (${arch_name})"
    rm -rf "$install_dir"
    mkdir -p "$install_dir"
    cd "$install_dir"

    wget -q -N --no-check-certificate -O "${install_dir}/XrayR-linux.zip" "$download_url"
    unzip -oq XrayR-linux.zip
    rm -f XrayR-linux.zip
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
    local escaped_api_host
    local escaped_panel_type
    local escaped_token
    local escaped_listen_ip
    local escaped_send_ip
    local escaped_ws_endpoint

    mkdir -p "$config_dir"
    tmp_config=$(mktemp "${config_file}.tmp.XXXXXX")

    escaped_api_host=$(yaml_escape "$api_host")
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

MachineConfig:
  Enable: true
  PanelType: "${escaped_panel_type}"
  ApiHost: "${escaped_api_host}"
  MachineID: ${machine_id}
  Token: "${escaped_token}"
  Timeout: ${timeout}
  DiscoveryInterval: ${discovery_interval}
  ControllerConfig:
    ListenIP: ${escaped_listen_ip}
    SendIP: ${escaped_send_ip}
    UpdatePeriodic: ${discovery_interval}
  WebSocketConfig:
    Enable: ${enable_ws}
EOF
        if [[ -n "$escaped_ws_endpoint" ]]; then
            echo "    Endpoint: \"${escaped_ws_endpoint}\""
        else
            echo "    Endpoint:"
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
    install_service
    install_management_script
    write_machine_config
    start_service

    info "XrayRP machine mode installation completed"
    print_next_steps
}

main "$@"
