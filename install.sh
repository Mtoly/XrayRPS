#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)
install_dir="${XRAYR_INSTALL_DIR:-/usr/local/XrayR}"
config_dir="${XRAYR_CONFIG_DIR:-/etc/XrayR}"
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

if [[ "${XRAYR_TEST_MODE:-0}" != "1" ]]; then
# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/alpine-release ]]; then
    release="alpine"
elif [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(arch)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

os_version=""

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar crontabs socat -y
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add --no-cache wget curl unzip tar dcron socat
    else
        apt update -y
        apt install wget curl unzip tar cron socat -y
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f "$service_file" ]]; then
        return 2
    fi
    if service_control is-active --quiet >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

download_https() {
    local url="$1"
    local destination="$2"

    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 \
        -o "$destination" "$url"
}

validate_release_version() {
    local candidate="$1"
    [[ "$candidate" =~ ^v?[0-9A-Za-z][0-9A-Za-z._-]*$ ]]
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

download_release_artifact() {
    local release_version="$1"
    local artifact_name="$2"
    local destination="$3"
    local release_dir

    release_dir=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-release.XXXXXX") || return 1
    if ! download_https "https://github.com/Mtoly/XrayRP/releases/download/${release_version}/${artifact_name}" "${release_dir}/${artifact_name}"; then
        rm -rf -- "$release_dir"
        return 1
    fi
    if ! download_https "https://github.com/Mtoly/XrayRP/releases/download/${release_version}/SHA256SUMS" "${release_dir}/SHA256SUMS"; then
        rm -rf -- "$release_dir"
        return 1
    fi
    if ! verify_release_checksum "$release_dir" "$artifact_name"; then
        rm -rf -- "$release_dir"
        return 1
    fi
    if ! cp -- "${release_dir}/${artifact_name}" "$destination"; then
        rm -rf -- "$release_dir"
        return 1
    fi
    rm -rf -- "$release_dir"
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


install_acme() {
    local script_file
    script_file=$(mktemp "${TMPDIR:-/tmp}/xrayr-acme.XXXXXX") || return 1
    if ! download_https "https://get.acme.sh" "$script_file"; then
        rm -f -- "$script_file"
        return 1
    fi
    sh "$script_file"
    local result=$?
    rm -f -- "$script_file"
    return "$result"
}

rollback_transaction() {
    local install_dir="$1"
    local backup_dir="$2"
    local had_previous="$3"
    local service_was_active="$4"
    if [[ -f "$service_file" ]] && ! service_control stop; then
        echo "Rollback failed to stop XrayR; preserved recovery files at $backup_dir." >&2
        return 1
    fi
    if [[ "$had_previous" == true && ! -d "$backup_dir" ]]; then
        echo "Rollback failed: original binary backup missing at $backup_dir." >&2
        return 1
    fi
    if ! rm -rf -- "$install_dir" ||
        { [[ "$had_previous" == true ]] && ! mv -- "$backup_dir" "$install_dir"; }; then
        echo "Rollback failed to restore binary; recovery files remain at $backup_dir." >&2
        return 1
    fi
    if ! restore_service_state "${backup_dir%/*}/service-state"; then
        echo "Rollback incomplete; recovery files remain at ${backup_dir%/*}." >&2
        return 1
    fi
}

abort_installation() {
    local transaction_dir="$1"
    local had_previous="$2"
    local reason="$3"
    rollback_transaction "$install_dir" "$transaction_dir/previous" "$had_previous" false || exit 1
    rm -rf -- "$transaction_dir"
    echo "$reason" >&2
    exit 1
}

install_XrayR() {
    local transaction_dir
    local staged_install
    local archive_file
    local backup_dir
    local metadata_file
    local last_version
    local artifact_name
    local service_tmp
    local file
    local management_script
    local had_previous="false"
    local service_was_active="false"
    local had_config="false"

    [[ -f "${config_dir}/config.yml" ]] && had_config="true"
    check_status && service_was_active="true"
    transaction_dir=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-install.XXXXXX") || exit 1
    staged_install="${transaction_dir}/new"
    archive_file="${transaction_dir}/XrayR-linux.zip"
    backup_dir="${transaction_dir}/previous"
    mkdir -p "$staged_install"
    snapshot_service_state "$transaction_dir/service-state" || {
        rm -rf -- "$transaction_dir"
        exit 1
    }

    if [ $# == 0 ]; then
        metadata_file=$(mktemp "${TMPDIR:-/tmp}/xrayr-release-metadata.XXXXXX") || exit 1
        if ! download_https "https://api.github.com/repos/Mtoly/XrayRP/releases/latest" "$metadata_file"; then
            rm -f -- "$metadata_file"
            rm -rf -- "$transaction_dir"
            echo -e "${red}检测 XrayR 版本失败，请稍后再试，或手动指定 XrayR 版本安装${plain}"
            exit 1
        fi
        last_version=$(grep '"tag_name":' "$metadata_file" | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1)
        rm -f -- "$metadata_file"
        if [[ -z "$last_version" ]] || ! validate_release_version "$last_version"; then
            rm -rf -- "$transaction_dir"
            echo -e "${red}检测到无效的 XrayR 发布版本${plain}"
            exit 1
        fi
        echo -e "检测到 XrayR 最新版本：${last_version}，开始安装"
    else
        if ! last_version=$(normalize_release_version "$1"); then
            rm -rf -- "$transaction_dir"
            echo -e "${red}XrayR 版本格式无效: $1${plain}"
            exit 1
        fi
        echo -e "开始安装 XrayR ${last_version}"
    fi

    artifact_name="XrayR-linux-${arch}.zip"
    if ! download_release_artifact "$last_version" "$artifact_name" "$archive_file"; then
        rm -rf -- "$transaction_dir"
        echo -e "${red}下载或校验 XrayR ${last_version} 失败，请确保此版本存在且发布校验文件可用${plain}"
        exit 1
    fi

    if ! unzip -oq "$archive_file" -d "$staged_install" || [[ ! -x "${staged_install}/XrayR" ]]; then
        rm -rf -- "$transaction_dir"
        echo -e "${red}XrayR 发布包解压或结构校验失败，保留现有安装${plain}"
        exit 1
    fi
    if [[ "$service_was_active" == true ]] && ! service_control stop; then
        rm -rf -- "$transaction_dir"
        echo "Failed to stop XrayR before upgrade; current installation preserved." >&2
        exit 1
    fi
    if [[ -d "$install_dir" ]]; then
        if ! mv -- "$install_dir" "$backup_dir"; then
            restore_service_state "$transaction_dir/service-state" || exit 1
            rm -rf -- "$transaction_dir"
            echo "Failed to back up the current installation." >&2
            exit 1
        fi
        had_previous="true"
    fi
    if ! mv -- "$staged_install" "$install_dir"; then
        if [[ "$had_previous" == true ]] && ! mv -- "$backup_dir" "$install_dir"; then
            echo "Activation and rollback failed; original binary remains at $backup_dir." >&2
            exit 1
        fi
        restore_service_state "$transaction_dir/service-state" || exit 1
        rm -rf -- "$transaction_dir"
        echo -e "${red}切换到新版本失败，已保留现有安装${plain}"
        exit 1
    fi
    cd "$install_dir" || abort_installation "$transaction_dir" "$had_previous" "Failed to enter the staged installation"
    chmod +x XrayR || abort_installation "$transaction_dir" "$had_previous" "Failed to set binary permissions"
    mkdir -p "$config_dir" || abort_installation "$transaction_dir" "$had_previous" "Failed to create the configuration directory"
    service_tmp=$(mktemp "${TMPDIR:-/tmp}/xrayr-service.XXXXXX") || {
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active" || exit 1
        rm -rf -- "$transaction_dir"
        exit 1
    }
    local service_asset=XrayR.service service_mode=0644
    if [[ "$service_manager" == openrc ]]; then
        service_asset=XrayR.openrc
        service_mode=0755
    fi
    file="https://raw.githubusercontent.com/Mtoly/XrayRPS/refs/heads/main/${service_asset}"
    if [[ -f "$cur_dir/$service_asset" ]]; then
        if ! cp -- "$cur_dir/$service_asset" "$service_tmp"; then
            rm -f -- "$service_tmp"
            abort_installation "$transaction_dir" "$had_previous" "Failed to copy XrayR $service_manager service definition"
        fi
    else
        download_https "$file" "$service_tmp" || {
            rm -f -- "$service_tmp"
            rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active" || exit 1
            rm -rf -- "$transaction_dir"
            echo "Failed to download XrayR $service_manager service definition." >&2
            exit 1
        }
    fi
    if ! install -m "$service_mode" "$service_tmp" "$service_file"; then
        rm -f -- "$service_tmp"
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active" || exit 1
        rm -rf -- "$transaction_dir"
        echo -e "${red}安装 XrayR ${service_manager} 服务文件失败；已尝试回滚，请检查上方结果${plain}"
        exit 1
    fi
    rm -f -- "$service_tmp"
    for file in geoip.dat geosite.dat; do
        if [[ -f "$file" ]]; then
            cp -f -- "$file" "${config_dir}/" ||
                abort_installation "$transaction_dir" "$had_previous" "Failed to copy $file into the configuration directory"
        fi
    done

    if [[ "$had_config" != "true" ]]; then
        cp -- config.yml "${config_dir}/" ||
            abort_installation "$transaction_dir" "$had_previous" "Failed to copy config.yml into the configuration directory"
        echo -e ""
        echo -e "全新安装，请先参看教程：https://github.com/Mtoly/XrayR，配置必要的内容"
    fi

    for file in dns.json route.json custom_outbound.json custom_inbound.json rulelist; do
        if [[ ! -f "${config_dir}/$file" ]]; then
            cp -- "$file" "${config_dir}/" ||
                abort_installation "$transaction_dir" "$had_previous" "Failed to copy $file into the configuration directory"
        fi
    done
    if ! ensure_service_permissions; then
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active" || exit 1
        rm -rf -- "$transaction_dir"
        echo -e "${red}设置 XrayR root 运行目录权限失败，已恢复之前的安装${plain}"
        exit 1
    fi

    if ! service_control daemon-reload; then
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active" || exit 1
        rm -rf -- "$transaction_dir"
        echo -e "${red}重新加载 systemd 配置失败，已恢复之前的安装${plain}"
        exit 1
    fi
    service_control stop >/dev/null 2>&1 || true
    if ! service_control enable; then
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active" || exit 1
        rm -rf -- "$transaction_dir"
        echo -e "${red}更新 XrayR systemd 服务失败，已恢复之前的安装${plain}"
        exit 1
    fi
    echo -e "${green}XrayR ${last_version}${plain} 安装完成，已设置开机自启"

    if [[ "$had_config" == "true" ]]; then
        if ! service_control start; then
            rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active" || exit 1
            rm -rf -- "$transaction_dir"
            echo -e "${red}XrayR 启动失败，已恢复之前的安装${plain}"
            exit 1
        fi
        sleep 2
        echo -e ""
        if check_status; then
            echo -e "${green}XrayR 重启成功${plain}"
        else
            rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active" || exit 1
            rm -rf -- "$transaction_dir"
            echo -e "${red}XrayR 启动失败，已恢复之前的安装${plain}"
            exit 1
        fi
    fi

    management_script=$(mktemp "${TMPDIR:-/tmp}/xrayr-management.XXXXXX") || {
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active" || exit 1
        rm -rf -- "$transaction_dir"
        exit 1
    }
    if ! download_https "https://raw.githubusercontent.com/Mtoly/XrayRPS/main/XrayR.sh" "$management_script" || ! install -m 755 "$management_script" /usr/bin/XrayR; then
        rm -f -- "$management_script"
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active" || exit 1
        rm -rf -- "$transaction_dir"
        echo -e "${red}下载 XrayR 管理脚本失败，已恢复之前的安装${plain}"
        exit 1
    fi
    rm -f -- "$management_script"
    ln -sf /usr/bin/XrayR /usr/bin/xrayr # 小写兼容
    chmod +x /usr/bin/xrayr
    cd $cur_dir
    rm -rf -- "$transaction_dir"
    rm -f install.sh
    echo -e ""
    echo "XrayR 管理脚本使用方法 (兼容使用xrayr执行，大小写不敏感): "
    echo "------------------------------------------"
    echo "XrayR                    - 显示管理菜单 (功能更多)"
    echo "XrayR start              - 启动 XrayR"
    echo "XrayR stop               - 停止 XrayR"
    echo "XrayR restart            - 重启 XrayR"
    echo "XrayR status             - 查看 XrayR 状态"
    echo "XrayR enable             - 设置 XrayR 开机自启"
    echo "XrayR disable            - 取消 XrayR 开机自启"
    echo "XrayR log                - 查看 XrayR 日志"
    echo "XrayR update             - 更新 XrayR"
    echo "XrayR update x.x.x       - 更新 XrayR 指定版本"
    echo "XrayR config             - 显示配置文件内容"
    echo "XrayR install            - 安装 XrayR"
    echo "XrayR uninstall          - 卸载 XrayR"
    echo "XrayR version            - 查看 XrayR 版本"
    echo "------------------------------------------"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    detect_service_manager || exit 1
    echo -e "${green}开始安装${plain}"
    install_base
    # install_acme
    install_XrayR "$@"
fi
