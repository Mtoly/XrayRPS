#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
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

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar crontabs socat -y
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

install_XrayR() {
    if [[ -e /usr/local/XrayR/ ]]; then
        rm /usr/local/XrayR/ -rf
    fi

    mkdir /usr/local/XrayR/ -p
	cd /usr/local/XrayR/

    if [ $# == 0 ]; then
        metadata_file=$(mktemp "${TMPDIR:-/tmp}/xrayr-release-metadata.XXXXXX") || exit 1
        if ! download_https "https://api.github.com/repos/Mtoly/XrayRP/releases/latest" "$metadata_file"; then
            rm -f -- "$metadata_file"
            echo -e "${red}检测 XrayR 版本失败，请稍后再试，或手动指定 XrayR 版本安装${plain}"
            exit 1
        fi
        last_version=$(grep '"tag_name":' "$metadata_file" | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1)
        rm -f -- "$metadata_file"
        if [[ -z "$last_version" ]] || ! validate_release_version "$last_version"; then
            echo -e "${red}检测到无效的 XrayR 发布版本${plain}"
            exit 1
        fi
        echo -e "检测到 XrayR 最新版本：${last_version}，开始安装"
    else
        last_version="$1"
        [[ "$last_version" == v* ]] || last_version="v${last_version}"
        if ! validate_release_version "$last_version"; then
            echo -e "${red}XrayR 版本格式无效: ${last_version}${plain}"
            exit 1
        fi
        echo -e "开始安装 XrayR ${last_version}"
    fi

    artifact_name="XrayR-linux-${arch}.zip"
    if ! download_release_artifact "$last_version" "$artifact_name" "/usr/local/XrayR/XrayR-linux.zip"; then
        echo -e "${red}下载或校验 XrayR ${last_version} 失败，请确保此版本存在且发布校验文件可用${plain}"
        exit 1
    fi

    unzip XrayR-linux.zip
    rm XrayR-linux.zip -f
    chmod +x XrayR
    mkdir /etc/XrayR/ -p
    service_file=$(mktemp "${TMPDIR:-/tmp}/xrayr-service.XXXXXX") || exit 1
    file="https://raw.githubusercontent.com/Mtoly/XrayRPS/refs/heads/main/XrayR.service"
    if ! download_https "$file" "$service_file" || ! install -m 644 "$service_file" /etc/systemd/system/XrayR.service; then
        rm -f -- "$service_file"
        echo -e "${red}下载 XrayR systemd 服务文件失败${plain}"
        exit 1
    fi
    rm -f -- "$service_file"
    #cp -f XrayR.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl stop XrayR
    systemctl enable XrayR
    echo -e "${green}XrayR ${last_version}${plain} 安装完成，已设置开机自启"
    cp geoip.dat /etc/XrayR/
    cp geosite.dat /etc/XrayR/ 

    if [[ ! -f /etc/XrayR/config.yml ]]; then
        cp config.yml /etc/XrayR/
        echo -e ""
        echo -e "全新安装，请先参看教程：https://github.com/Mtoly/XrayR，配置必要的内容"
    else
        systemctl start XrayR
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}XrayR 重启成功${plain}"
        else
            echo -e "${red}XrayR 可能启动失败，请稍后使用 XrayR log 查看日志信息，若无法启动，则可能更改了配置格式，请前往 wiki 查看：https://github.com/Mtoly/XrayR/wiki${plain}"
        fi
    fi

    if [[ ! -f /etc/XrayR/dns.json ]]; then
        cp dns.json /etc/XrayR/
    fi
    if [[ ! -f /etc/XrayR/route.json ]]; then
        cp route.json /etc/XrayR/
    fi
    if [[ ! -f /etc/XrayR/custom_outbound.json ]]; then
        cp custom_outbound.json /etc/XrayR/
    fi
    if [[ ! -f /etc/XrayR/custom_inbound.json ]]; then
        cp custom_inbound.json /etc/XrayR/
    fi
    if [[ ! -f /etc/XrayR/rulelist ]]; then
        cp rulelist /etc/XrayR/
    fi
    management_script=$(mktemp "${TMPDIR:-/tmp}/xrayr-management.XXXXXX") || exit 1
    if ! download_https "https://raw.githubusercontent.com/Mtoly/XrayRPS/main/XrayR.sh" "$management_script" || ! install -m 755 "$management_script" /usr/bin/XrayR; then
        rm -f -- "$management_script"
        echo -e "${red}下载 XrayR 管理脚本失败${plain}"
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

echo -e "${green}开始安装${plain}"
install_base
# install_acme
install_XrayR $1
