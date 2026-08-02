#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

version="v1.0.0"
config_file="${XRAYR_CONFIG_FILE:-/etc/XrayR/config.yml}"
service_file="${XRAYR_SERVICE_FILE:-/etc/systemd/system/XrayR.service}"

if [[ "${XRAYR_TEST_MODE:-0}" != "1" ]]; then
# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误: ${plain} 必须使用root用户运行此脚本！\n" && exit 1

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

confirm() {
    if [[ $# -gt 1 ]]; then
        echo && read -p "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -p "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "是否重启XrayR" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/Mtoly/XrayRPS/main/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    if [[ $# == 0 ]]; then
        echo && echo -n -e "输入指定版本(默认最新版): " && read version
    else
        version=$2
    fi
#    confirm "本功能会强制重装当前最新版，数据不会丢失，是否继续?" "n"
#    if [[ $? != 0 ]]; then
#        echo -e "${red}已取消${plain}"
#        if [[ $1 != 0 ]]; then
#            before_show_menu
#        fi
#        return 0
#    fi
    bash <(curl -Ls https://raw.githubusercontent.com/Mtoly/XrayRPS/main/install.sh) $version
    if [[ $? == 0 ]]; then
        echo -e "${green}更新完成，已自动重启 XrayR，请使用 XrayR log 查看运行日志${plain}"
        exit
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

config() {
    echo "XrayR在修改配置后会自动尝试重启"
    vi /etc/XrayR/config.yml
    sleep 2
    check_status
    case $? in
        0)
            echo -e "XrayR状态: ${green}已运行${plain}"
            ;;
        1)
            echo -e "检测到您未启动XrayR或XrayR自动重启失败，是否查看日志？[Y/n]" && echo
            read -e -p "(默认: y):" yn
            [[ -z ${yn} ]] && yn="y"
            if [[ ${yn} == [Yy] ]]; then
               show_log
            fi
            ;;
        2)
            echo -e "XrayR状态: ${red}未安装${plain}"
    esac
}

uninstall() {
    confirm "确定要卸载 XrayR 吗?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    systemctl stop XrayR
    systemctl disable XrayR
    rm /etc/systemd/system/XrayR.service -f
    systemctl daemon-reload
    systemctl reset-failed
    rm /etc/XrayR/ -rf
    rm /usr/local/XrayR/ -rf

    echo ""
    echo -e "卸载成功，如果你想删除此脚本，则退出脚本后运行 ${green}rm /usr/bin/XrayR -f${plain} 进行删除"
    echo ""

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}XrayR已运行，无需再次启动，如需重启请选择重启${plain}"
    else
        systemctl start XrayR
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}XrayR 启动成功，请使用 XrayR log 查看运行日志${plain}"
        else
            echo -e "${red}XrayR可能启动失败，请稍后使用 XrayR log 查看日志信息${plain}"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    systemctl stop XrayR
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}XrayR 停止成功${plain}"
    else
        echo -e "${red}XrayR停止失败，可能是因为停止时间超过了两秒，请稍后查看日志信息${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    systemctl restart XrayR
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}XrayR 重启成功，请使用 XrayR log 查看运行日志${plain}"
    else
        echo -e "${red}XrayR可能启动失败，请稍后使用 XrayR log 查看日志信息${plain}"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
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

observability_json_status() {
    local response_file="$1"
    sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$response_file" | head -n 1
}

observability_fetch() {
    local base_url="$1"
    local endpoint="$2"
    local output_file="$3"

    observability_http_code=""
    if ! observability_http_code=$(curl -sS \
        --connect-timeout 1 \
        --max-time 3 \
        --retry 0 \
        -o "$output_file" \
        -w '%{http_code}' \
        "${base_url}${endpoint}" 2>/dev/null); then
        return 1
    fi
    [[ "$observability_http_code" =~ ^[0-9]{3}$ ]]
}

observability_reason_text() {
    local response_file="$1"
    local reason="$2"

    grep -Fq "\"${reason}\"" "$response_file"
}

parse_observability_metrics() {
    local response_file="$1"

    awk '
        function metric_label(sample, key, prefix, remainder, end_quote) {
            prefix = key "=\""
            if (index(sample, prefix) == 0) {
                return ""
            }
            remainder = substr(sample, index(sample, prefix) + length(prefix))
            end_quote = index(remainder, "\"")
            if (end_quote == 0) {
                return ""
            }
            return substr(remainder, 1, end_quote - 1)
        }

        function numeric(value) {
            return value ~ /^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/
        }

        function lifecycle_rank(value) {
            if (value == "running") return 1
            if (value == "stopped") return 2
            if (value == "reloading") return 3
            if (value == "starting") return 4
            if (value == "retiring") return 5
            if (value == "stopping") return 6
            if (value == "failed") return 7
            if (value == "failed-owned") return 8
            if (value == "closed") return 9
            return 0
        }

        function bounded_failure_stage(value) {
            return value == "none" || value == "start" || value == "sync" ||
                value == "websocket" || value == "reconcile" || value == "report" ||
                value == "certificate" || value == "runtime" || value == "close" ||
                value == "cleanup"
        }

        /^[[:space:]]*#/ || NF < 2 {
            next
        }

        {
            sample = $1
            value = $2
            name = sample
            sub(/\{.*/, "", name)
            if (name != "xrayrp_live" &&
                name != "xrayrp_ready" &&
                name != "xrayrp_runtime_state" &&
                name != "xrayrp_topology_generation" &&
                name != "xrayrp_last_successful_sync_timestamp_seconds" &&
                name != "xrayrp_last_failure_timestamp_seconds" &&
                name != "xrayrp_cleanup_pending" &&
                name != "xrayrp_traffic_report_backlog" &&
                name != "xrayrp_certificate_expiry_timestamp_seconds") {
                next
            }
            if (!numeric(value)) {
                next
            }
            valid_metric = 1
            slot = metric_label(sample, "node_slot")

            if (name == "xrayrp_runtime_state" && value + 0 == 1) {
                websocket = metric_label(sample, "websocket")
                if (websocket == "degraded" || websocket == "disconnected") {
                    websocket_degraded = 1
                } else if (websocket == "connected") {
                    websocket_connected = 1
                }

                lifecycle = metric_label(sample, "lifecycle")
                rank = lifecycle_rank(lifecycle)
                if (rank > selected_lifecycle_rank) {
                    selected_lifecycle_rank = rank
                    selected_lifecycle = lifecycle
                }
            } else if (name == "xrayrp_topology_generation") {
                if (value + 0 > topology_generation) {
                    topology_generation = value + 0
                }
            } else if (name == "xrayrp_last_successful_sync_timestamp_seconds") {
                if (value + 0 > last_successful_sync) {
                    last_successful_sync = value + 0
                }
            } else if (name == "xrayrp_last_failure_timestamp_seconds") {
                if (value + 0 > last_failure) {
                    last_failure = value + 0
                    candidate_stage = metric_label(sample, "failure_stage")
                    if (bounded_failure_stage(candidate_stage)) {
                        last_failure_stage = candidate_stage
                    } else {
                        last_failure_stage = "unknown"
                    }
                }
            } else if (name == "xrayrp_cleanup_pending") {
                if (slot != "") {
                    has_node_slot = 1
                    if (!(slot in cleanup_by_slot) || value + 0 > cleanup_by_slot[slot]) {
                        cleanup_by_slot[slot] = value + 0
                    }
                } else if (value + 0 > root_cleanup) {
                    root_cleanup = value + 0
                }
            } else if (name == "xrayrp_traffic_report_backlog") {
                if (slot != "") {
                    has_node_slot = 1
                    if (!(slot in backlog_by_slot) || value + 0 > backlog_by_slot[slot]) {
                        backlog_by_slot[slot] = value + 0
                    }
                } else if (value + 0 > root_backlog) {
                    root_backlog = value + 0
                }
            } else if (name == "xrayrp_certificate_expiry_timestamp_seconds" && value + 0 > 0) {
                if (slot != "") {
                    has_node_slot = 1
                    if (!(slot in certificate_by_slot) || value + 0 < certificate_by_slot[slot]) {
                        certificate_by_slot[slot] = value + 0
                    }
                } else if (root_certificate == 0 || value + 0 < root_certificate) {
                    root_certificate = value + 0
                }
            }
        }

        END {
            if (!valid_metric) {
                exit 1
            }

            if (websocket_degraded) {
                websocket_summary = "degraded"
            } else if (websocket_connected) {
                websocket_summary = "connected"
            } else {
                websocket_summary = "disabled"
            }

            cleanup_pending = root_cleanup + 0
            traffic_backlog = root_backlog + 0
            certificate_expiry = root_certificate + 0
            if (has_node_slot) {
                cleanup_pending = 0
                traffic_backlog = 0
                certificate_expiry = 0
                for (slot_key in cleanup_by_slot) {
                    cleanup_pending += cleanup_by_slot[slot_key]
                }
                for (slot_key in backlog_by_slot) {
                    traffic_backlog += backlog_by_slot[slot_key]
                }
                for (slot_key in certificate_by_slot) {
                    if (certificate_expiry == 0 || certificate_by_slot[slot_key] < certificate_expiry) {
                        certificate_expiry = certificate_by_slot[slot_key]
                    }
                }
            }

            if (last_failure_stage == "") {
                last_failure_stage = "none"
            }
            if (selected_lifecycle == "") {
                selected_lifecycle = "unknown"
            }

            print "websocket=" websocket_summary
            printf "topology_generation=%.0f\n", topology_generation + 0
            printf "last_successful_sync=%.0f\n", last_successful_sync + 0
            printf "last_failure=%.0f\n", last_failure + 0
            print "last_failure_stage=" last_failure_stage
            printf "cleanup_pending=%.0f\n", cleanup_pending
            printf "traffic_backlog=%.0f\n", traffic_backlog
            printf "certificate_expiry=%.0f\n", certificate_expiry
            print "lifecycle=" selected_lifecycle
        }
    ' "$response_file"
}

observability_format_timestamp() {
    local timestamp="$1"
    local format="$2"
    local formatted

    if [[ "$timestamp" == "0" || -z "$timestamp" ]]; then
        echo "暂无数据"
        return
    fi
    if formatted=$(date -d "@$timestamp" "+$format" 2>/dev/null); then
        echo "$formatted"
    elif formatted=$(date -r "$timestamp" "+$format" 2>/dev/null); then
        echo "$formatted"
    else
        echo "暂无数据"
    fi
}

observability_failure_stage_text() {
    case "$1" in
        none) echo "无" ;;
        start) echo "启动" ;;
        sync) echo "同步" ;;
        websocket) echo "WebSocket" ;;
        reconcile) echo "拓扑更新" ;;
        report) echo "流量上报" ;;
        certificate) echo "证书" ;;
        runtime) echo "运行时" ;;
        close) echo "关闭" ;;
        cleanup) echo "清理" ;;
        *) echo "未知" ;;
    esac
}

observability_lifecycle_text() {
    case "$1" in
        stopped) echo "已停止" ;;
        starting) echo "启动中" ;;
        running) echo "运行中" ;;
        reloading) echo "重新加载" ;;
        stopping) echo "正在停止" ;;
        failed) echo "失败" ;;
        failed-owned) echo "失败，资源待清理" ;;
        retiring) echo "退役中" ;;
        closed) echo "已关闭" ;;
        *) echo "未知" ;;
    esac
}

show_observability_metrics() {
    local summary_file="$1"
    local key
    local value
    local websocket="disabled"
    local topology_generation="0"
    local last_successful_sync="0"
    local last_failure="0"
    local last_failure_stage="none"
    local cleanup_pending="0"
    local traffic_backlog="0"
    local certificate_expiry="0"
    local lifecycle="unknown"

    while IFS='=' read -r key value; do
        case "$key" in
            websocket) websocket="$value" ;;
            topology_generation) topology_generation="$value" ;;
            last_successful_sync) last_successful_sync="$value" ;;
            last_failure) last_failure="$value" ;;
            last_failure_stage) last_failure_stage="$value" ;;
            cleanup_pending) cleanup_pending="$value" ;;
            traffic_backlog) traffic_backlog="$value" ;;
            certificate_expiry) certificate_expiry="$value" ;;
            lifecycle) lifecycle="$value" ;;
        esac
    done < "$summary_file"

    case "$websocket" in
        connected) echo "WebSocket：已连接" ;;
        degraded) echo "WebSocket：降级" ;;
        *) echo "WebSocket：未启用" ;;
    esac
    echo "拓扑版本：$topology_generation"
    echo "最后同步：$(observability_format_timestamp "$last_successful_sync" '%Y-%m-%d %H:%M:%S')"
    echo "最后失败：$(observability_format_timestamp "$last_failure" '%Y-%m-%d %H:%M:%S')"
    echo "最后失败阶段：$(observability_failure_stage_text "$last_failure_stage")"
    echo "待清理资源：$cleanup_pending"
    echo "流量上报积压：$traffic_backlog"
    echo "证书到期：$(observability_format_timestamp "$certificate_expiry" '%Y-%m-%d')"
    echo "运行状态：$(observability_lifecycle_text "$lifecycle")"
}

show_observability_status() {
    local enabled
    local listen
    local base_url
    local response_dir
    local live_status
    local ready_status
    local reason
    local reason_text
    local joined_reasons=""
    local -a translated_reasons=()

    if ! enabled=$(read_yaml_section_scalar "$config_file" "Observability" "Enable" 2>/dev/null); then
        echo "状态接口未启用"
        return 0
    fi
    if [[ "${enabled,,}" != "true" ]]; then
        echo "状态接口未启用"
        return 0
    fi

    if ! listen=$(read_yaml_section_scalar "$config_file" "Observability" "Listen" 2>/dev/null) || [[ -z "$listen" ]]; then
        listen="127.0.0.1:10085"
    fi
    if [[ -n "${XRAYR_OBSERVABILITY_URL:-}" ]]; then
        base_url="$XRAYR_OBSERVABILITY_URL"
    else
        base_url="http://$listen"
    fi
    base_url="${base_url%/}"

    if ! response_dir=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-observability.XXXXXX"); then
        echo "状态接口不可访问"
        return 0
    fi

    if ! observability_fetch "$base_url" "/livez" "${response_dir}/livez"; then
        echo "状态接口不可访问"
        rm -f "${response_dir}/livez"
        rmdir "$response_dir" 2>/dev/null || true
        return 0
    fi
    live_status=$(observability_json_status "${response_dir}/livez")
    if [[ "$observability_http_code" == "200" && "$live_status" == "live" ]]; then
        echo "程序存活：正常"
    elif [[ "$observability_http_code" == "503" || "$live_status" == "shutdown" ]]; then
        echo "程序存活：正在关闭"
    else
        echo "状态接口不可访问"
        rm -f "${response_dir}/livez"
        rmdir "$response_dir" 2>/dev/null || true
        return 0
    fi

    if ! observability_fetch "$base_url" "/readyz" "${response_dir}/readyz"; then
        echo "节点就绪：状态接口不可访问"
        rm -f "${response_dir}/livez" "${response_dir}/readyz"
        rmdir "$response_dir" 2>/dev/null || true
        return 0
    fi
    ready_status=$(observability_json_status "${response_dir}/readyz")
    if [[ "$observability_http_code" == "200" && "$ready_status" == "ready" ]]; then
        echo "节点就绪：正常"
    elif [[ "$observability_http_code" == "200" && "$ready_status" == "degraded" ]]; then
        echo "节点就绪：降级"
    elif [[ "$observability_http_code" == "503" && "$ready_status" == "not_ready" ]]; then
        while IFS='|' read -r reason reason_text; do
            if observability_reason_text "${response_dir}/readyz" "$reason"; then
                translated_reasons+=("$reason_text")
            fi
        done <<'EOF'
shutdown|程序正在关闭
lifecycle|节点生命周期异常
cleanup_pending|资源等待清理
sync_unavailable|尚无成功同步
sync_stale|同步状态过期
certificate_expired|证书已过期
EOF
        for reason_text in "${translated_reasons[@]}"; do
            if [[ -n "$joined_reasons" ]]; then
                joined_reasons+="、"
            fi
            joined_reasons+="$reason_text"
        done
        if [[ -n "$joined_reasons" ]]; then
            echo "节点就绪：未就绪（${joined_reasons}）"
        else
            echo "节点就绪：未就绪"
        fi
    else
        echo "节点就绪：状态接口不可访问"
    fi

    if observability_fetch "$base_url" "/metrics" "${response_dir}/metrics" &&
        [[ "$observability_http_code" == "200" ]] &&
        parse_observability_metrics "${response_dir}/metrics" > "${response_dir}/summary"; then
        show_observability_metrics "${response_dir}/summary"
    else
        echo "详细运行状态：不可用"
    fi

    rm -f "${response_dir}/livez" "${response_dir}/readyz" "${response_dir}/metrics" "${response_dir}/summary"
    rmdir "$response_dir" 2>/dev/null || true
    return 0
}

status() {
    systemctl status XrayR --no-pager -l || true
    check_status
    case $? in
        0)
            echo "系统服务：运行中"
            ;;
        1)
            echo "系统服务：未运行"
            ;;
        2)
            echo "系统服务：未安装"
            ;;
    esac
    show_observability_status
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    systemctl enable XrayR
    if [[ $? == 0 ]]; then
        echo -e "${green}XrayR 设置开机自启成功${plain}"
    else
        echo -e "${red}XrayR 设置开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    systemctl disable XrayR
    if [[ $? == 0 ]]; then
        echo -e "${green}XrayR 取消开机自启成功${plain}"
    else
        echo -e "${red}XrayR 取消开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    journalctl -u XrayR.service -e --no-pager -f
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

install_bbr() {
    bash <(curl -L -s https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/master/tcp.sh)
    #if [[ $? == 0 ]]; then
    #    echo ""
    #    echo -e "${green}安装 bbr 成功，请重启服务器${plain}"
    #else
    #    echo ""
    #    echo -e "${red}下载 bbr 安装脚本失败，请检查本机能否连接 Github${plain}"
    #fi

    #before_show_menu
}

update_shell() {
    wget -O /usr/bin/XrayR -N --no-check-certificate https://raw.githubusercontent.com/Mtoly/XrayRPS/main/XrayR.sh
    if [[ $? != 0 ]]; then
        echo ""
        echo -e "${red}下载脚本失败，请检查本机能否连接 Github${plain}"
        before_show_menu
    else
        chmod +x /usr/bin/XrayR
        echo -e "${green}升级脚本成功，请重新运行脚本${plain}" && exit 0
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f "$service_file" ]]; then
        return 2
    fi
    if systemctl is-active --quiet XrayR >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

check_enabled() {
    temp=$(systemctl is-enabled XrayR)
    if [[ x"${temp}" == x"enabled" ]]; then
        return 0
    else
        return 1;
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        echo -e "${red}XrayR已安装，请不要重复安装${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        echo -e "${red}请先安装XrayR${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "XrayR状态: ${green}已运行${plain}"
            show_enable_status
            ;;
        1)
            echo -e "XrayR状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "XrayR状态: ${red}未安装${plain}"
    esac
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

show_XrayR_version() {
    echo -n "XrayR 版本："
    /usr/local/XrayR/XrayR version
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_usage() {
    echo "XrayR 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "XrayR              - 显示管理菜单 (功能更多)"
    echo "XrayR start        - 启动 XrayR"
    echo "XrayR stop         - 停止 XrayR"
    echo "XrayR restart      - 重启 XrayR"
    echo "XrayR status       - 查看 XrayR 状态"
    echo "XrayR enable       - 设置 XrayR 开机自启"
    echo "XrayR disable      - 取消 XrayR 开机自启"
    echo "XrayR log          - 查看 XrayR 日志"
    echo "XrayR update       - 更新 XrayR"
    echo "XrayR update x.x.x - 更新 XrayR 指定版本"
    echo "XrayR install      - 安装 XrayR"
    echo "XrayR uninstall    - 卸载 XrayR"
    echo "XrayR version      - 查看 XrayR 版本"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}XrayR 后端管理脚本，${plain}${red}不适用于docker${plain}
--- https://github.com/Mtoly/XrayRP ---
  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 XrayR
  ${green}2.${plain} 更新 XrayR
  ${green}3.${plain} 卸载 XrayR
————————————————
  ${green}4.${plain} 启动 XrayR
  ${green}5.${plain} 停止 XrayR
  ${green}6.${plain} 重启 XrayR
  ${green}7.${plain} 查看 XrayR 状态
  ${green}8.${plain} 查看 XrayR 日志
————————————————
  ${green}9.${plain} 设置 XrayR 开机自启
 ${green}10.${plain} 取消 XrayR 开机自启
————————————————
 ${green}11.${plain} 一键安装 bbr (最新内核)
 ${green}12.${plain} 查看 XrayR 版本 
 ${green}13.${plain} 升级维护脚本
 "
 #后续更新可加入上方字符串中
    show_status
    echo && read -p "请输入选择 [0-13]: " num

    case "${num}" in
        0) config
        ;;
        1) check_uninstall && install
        ;;
        2) check_install && update
        ;;
        3) check_install && uninstall
        ;;
        4) check_install && start
        ;;
        5) check_install && stop
        ;;
        6) check_install && restart
        ;;
        7) check_install && status
        ;;
        8) check_install && show_log
        ;;
        9) check_install && enable
        ;;
        10) check_install && disable
        ;;
        11) install_bbr
        ;;
        12) check_install && show_XrayR_version
        ;;
        13) update_shell
        ;;
        *) echo -e "${red}请输入正确的数字 [0-12]${plain}"
        ;;
    esac
}


if [[ $# -gt 0 ]]; then
    case $1 in
        "start") check_install 0 && start 0
        ;;
        "stop") check_install 0 && stop 0
        ;;
        "restart") check_install 0 && restart 0
        ;;
        "status") check_install 0 && status 0
        ;;
        "enable") check_install 0 && enable 0
        ;;
        "disable") check_install 0 && disable 0
        ;;
        "log") check_install 0 && show_log 0
        ;;
        "update") check_install 0 && update 0 $2
        ;;
        "config") config "$@"
        ;;
        "install") check_uninstall 0 && install 0
        ;;
        "uninstall") check_install 0 && uninstall 0
        ;;
        "version") check_install 0 && show_XrayR_version 0
        ;;
        "update_shell") update_shell
        ;;
        *) show_usage
    esac
else
    show_menu
fi
