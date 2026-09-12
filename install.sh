#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)
install_dir="${XRAYR_INSTALL_DIR:-/usr/local/XrayR}"
config_dir="${XRAYR_CONFIG_DIR:-/etc/XrayR}"
service_file="${XRAYR_SERVICE_FILE:-/etc/systemd/system/XrayR.service}"

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
    if [[ ! -f /etc/systemd/system/XrayR.service ]]; then
        return 2
    fi
    temp=$(systemctl status XrayR | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
    if [[ x"${temp}" == x"running" ]]; then
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

service_user_exists() {
    local account_name="${1:-xrayr}"
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$account_name" >/dev/null 2>&1
    else
        id "$account_name" >/dev/null 2>&1
    fi
}

service_group_exists() {
    local group_name="${1:-xrayr}"
    if command -v getent >/dev/null 2>&1; then
        getent group "$group_name" >/dev/null 2>&1
    else
        grep -qE "^${group_name}:" /etc/group
    fi
}

service_nologin_shell() {
    local shell_path
    for shell_path in /usr/sbin/nologin /sbin/nologin /bin/false; do
        if [[ -x "$shell_path" ]]; then
            printf '%s' "$shell_path"
            return 0
        fi
    done
    printf '%s' /bin/false
}

command_is_busybox() {
    local command_name="$1"
    local help_text
    help_text=$("$command_name" --help 2>&1 || true)
    [[ "$help_text" == *BusyBox* ]]
}

create_service_group() {
    local group_name="$1"

    if command -v groupadd >/dev/null 2>&1 && groupadd --system "$group_name"; then
        return 0
    fi
    if command -v addgroup >/dev/null 2>&1; then
        if command_is_busybox addgroup; then
            addgroup -S "$group_name"
        else
            addgroup --system "$group_name"
        fi
        return $?
    fi

    echo "Error: neither groupadd nor addgroup could create ${group_name}" >&2
    return 1
}

create_service_user() {
    local account_name="$1"
    local group_name="$2"
    local home_dir="$3"
    local login_shell="$4"
    if command -v useradd >/dev/null 2>&1 && useradd --system --gid "$group_name" \
        --home-dir "$home_dir" --no-create-home --shell "$login_shell" "$account_name"; then
        return 0
    fi
    if command -v adduser >/dev/null 2>&1; then
        if command_is_busybox adduser; then
            adduser -S -D -H -h "$home_dir" -s "$login_shell" \
                -G "$group_name" -g "$account_name" "$account_name"
        else
            adduser --system --ingroup "$group_name" --home "$home_dir" \
                --no-create-home --shell "$login_shell" "$account_name"
        fi
        return $?
    fi

    echo "Error: neither useradd nor adduser could create ${account_name}" >&2
    return 1
}

ensure_service_account() {
    local account_name="${XRAYR_SERVICE_USER:-xrayr}"
    local group_name="${XRAYR_SERVICE_GROUP:-xrayr}"
    local home_dir="${XRAYR_SERVICE_HOME:-/var/lib/xrayr}"
    local login_shell
    login_shell=$(service_nologin_shell)

    if ! service_group_exists "$group_name"; then
        if ! create_service_group "$group_name" && ! service_group_exists "$group_name"; then
            echo "Error: failed to create service group ${group_name}" >&2
            return 1
        fi
    fi
    if ! service_group_exists "$group_name"; then
        echo "Error: service group ${group_name} is unavailable" >&2
        return 1
    fi

    if ! service_user_exists "$account_name"; then
        if ! create_service_user "$account_name" "$group_name" "$home_dir" "$login_shell" && \
            ! service_user_exists "$account_name"; then
            echo "Error: failed to create service user ${account_name}" >&2
            return 1
        fi
    fi
    if ! service_user_exists "$account_name"; then
        echo "Error: service user ${account_name} is unavailable" >&2
        return 1
    fi

    if ! install -d -o "$account_name" -g "$group_name" -m 0750 "$home_dir"; then
        echo "Error: failed to prepare service home ${home_dir}" >&2
        return 1
    fi
}

ensure_service_permissions() {
    local account_name="${XRAYR_SERVICE_USER:-xrayr}"
    local group_name="${XRAYR_SERVICE_GROUP:-xrayr}"
    local home_dir="${XRAYR_SERVICE_HOME:-/var/lib/xrayr}"
    local runtime_dir="${XRAYR_INSTALL_DIR:-/usr/local/XrayR}"
    local settings_dir="${XRAYR_CONFIG_DIR:-/etc/XrayR}"

    install -d -o "$account_name" -g "$group_name" -m 0750 "$home_dir" "$settings_dir" || return 1
    if [[ -d "$runtime_dir" ]]; then
        chown -R "root:${group_name}" "$runtime_dir" || return 1
        find "$runtime_dir" -type d -exec chmod 0750 {} + || return 1
        find "$runtime_dir" -type f -exec chmod 0640 {} + || return 1
        [[ ! -f "$runtime_dir/XrayR" ]] || chmod 0750 "$runtime_dir/XrayR" || return 1
    fi
    chown -R "${account_name}:${group_name}" "$settings_dir" || return 1
    find "$settings_dir" -type d -exec chmod 0750 {} + || return 1
    find "$settings_dir" -type f -exec chmod 0640 {} + || return 1
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
    systemctl stop XrayR >/dev/null 2>&1 || true
    rm -rf -- "$install_dir"
    if [[ "$had_previous" == "true" && -d "$backup_dir" ]]; then
        mv -- "$backup_dir" "$install_dir"
        [[ "$service_was_active" == "true" ]] && systemctl start XrayR >/dev/null 2>&1 || true
    fi
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
        last_version="$1"
        [[ "$last_version" == v* ]] || last_version="v${last_version}"
        if ! validate_release_version "$last_version"; then
            rm -rf -- "$transaction_dir"
            echo -e "${red}XrayR 版本格式无效: ${last_version}${plain}"
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
    if [[ -d "$install_dir" ]]; then
        mv -- "$install_dir" "$backup_dir"
        had_previous="true"
    fi
    if ! mv -- "$staged_install" "$install_dir"; then
        [[ "$had_previous" == "true" ]] && mv -- "$backup_dir" "$install_dir"
        rm -rf -- "$transaction_dir"
        echo -e "${red}切换到新版本失败，已保留现有安装${plain}"
        exit 1
    fi
    cd "$install_dir"
    chmod +x XrayR
    if ! ensure_service_account; then
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active"
        rm -rf -- "$transaction_dir"
        echo -e "${red}创建 XrayR 服务账户失败，已恢复之前的安装${plain}"
        exit 1
    fi
    mkdir -p "$config_dir"
    service_tmp=$(mktemp "${TMPDIR:-/tmp}/xrayr-service.XXXXXX") || {
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active"
        rm -rf -- "$transaction_dir"
        exit 1
    }
    file="https://raw.githubusercontent.com/Mtoly/XrayRPS/refs/heads/main/XrayR.service"
    if ! download_https "$file" "$service_tmp" || ! install -m 0644 "$service_tmp" "$service_file"; then
        rm -f -- "$service_tmp"
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active"
        rm -rf -- "$transaction_dir"
        echo -e "${red}下载 XrayR systemd 服务文件失败，已恢复之前的安装${plain}"
        exit 1
    fi
    rm -f -- "$service_tmp"
    [[ -f geoip.dat ]] && cp -f geoip.dat "${config_dir}/"
    [[ -f geosite.dat ]] && cp -f geosite.dat "${config_dir}/"

    if [[ "$had_config" != "true" ]]; then
        cp config.yml "${config_dir}/"
        echo -e ""
        echo -e "全新安装，请先参看教程：https://github.com/Mtoly/XrayR，配置必要的内容"
    fi

    if [[ ! -f "${config_dir}/dns.json" ]]; then
        cp dns.json "${config_dir}/"
    fi
    if [[ ! -f "${config_dir}/route.json" ]]; then
        cp route.json "${config_dir}/"
    fi
    if [[ ! -f "${config_dir}/custom_outbound.json" ]]; then
        cp custom_outbound.json "${config_dir}/"
    fi
    if [[ ! -f "${config_dir}/custom_inbound.json" ]]; then
        cp custom_inbound.json "${config_dir}/"
    fi
    if [[ ! -f "${config_dir}/rulelist" ]]; then
        cp rulelist "${config_dir}/"
    fi
    if ! ensure_service_permissions; then
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active"
        rm -rf -- "$transaction_dir"
        echo -e "${red}设置 XrayR 文件权限失败，已恢复之前的安装${plain}"
        exit 1
    fi

    if ! systemctl daemon-reload; then
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active"
        rm -rf -- "$transaction_dir"
        echo -e "${red}重新加载 systemd 配置失败，已恢复之前的安装${plain}"
        exit 1
    fi
    systemctl stop XrayR >/dev/null 2>&1 || true
    if ! systemctl enable XrayR; then
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active"
        rm -rf -- "$transaction_dir"
        echo -e "${red}更新 XrayR systemd 服务失败，已恢复之前的安装${plain}"
        exit 1
    fi
    echo -e "${green}XrayR ${last_version}${plain} 安装完成，已设置开机自启"

    if [[ "$had_config" == "true" ]]; then
        if ! systemctl start XrayR; then
            rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active"
            rm -rf -- "$transaction_dir"
            echo -e "${red}XrayR 启动失败，已恢复之前的安装${plain}"
            exit 1
        fi
        sleep 2
        echo -e ""
        if check_status; then
            echo -e "${green}XrayR 重启成功${plain}"
        else
            rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active"
            rm -rf -- "$transaction_dir"
            echo -e "${red}XrayR 启动失败，已恢复之前的安装${plain}"
            exit 1
        fi
    fi

    management_script=$(mktemp "${TMPDIR:-/tmp}/xrayr-management.XXXXXX") || {
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active"
        rm -rf -- "$transaction_dir"
        exit 1
    }
    if ! download_https "https://raw.githubusercontent.com/Mtoly/XrayRPS/main/XrayR.sh" "$management_script" || ! install -m 755 "$management_script" /usr/bin/XrayR; then
        rm -f -- "$management_script"
        rollback_transaction "$install_dir" "$backup_dir" "$had_previous" "$service_was_active"
        rm -rf -- "$transaction_dir"
        echo -e "${red}下载 XrayR 管理脚本失败，已恢复之前的安装${plain}"
        exit 1
    fi
    rm -f -- "$management_script"
    ln -s /usr/bin/XrayR /usr/bin/xrayr # 小写兼容
    chmod +x /usr/bin/xrayr
    cd $cur_dir
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
    echo -e "${green}开始安装${plain}"
    install_base
    # install_acme
    install_XrayR "$@"
fi
