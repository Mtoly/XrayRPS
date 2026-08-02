#!/bin/bash

set -euo pipefail

# shellcheck source=test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir=$(new_temp_dir)
trap 'remove_temp_dir "$test_dir"' EXIT

mock_bin="${test_dir}/bin"
mock_http="${test_dir}/http"
mock_calls="${test_dir}/calls.log"
service_file="${test_dir}/XrayR.service"
config_file="${test_dir}/config.yml"
mock_tmp="${test_dir}/tmp"
mkdir -p "$mock_bin" "$mock_http" "$mock_tmp"
: > "$service_file"

cat > "${mock_bin}/systemctl" <<'EOF'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$MOCK_CALLS"
case "${1:-}" in
    status)
        echo "Mock systemd status: Active: active (running)"
        exit "${MOCK_SYSTEMCTL_STATUS_EXIT:-0}"
        ;;
    is-active)
        [[ "${MOCK_SERVICE_ACTIVE:-true}" == "true" ]]
        ;;
    *)
        exit 0
        ;;
esac
EOF

cat > "${mock_bin}/curl" <<'EOF'
#!/bin/bash
printf 'curl' >> "$MOCK_CALLS"
printf ' %q' "$@" >> "$MOCK_CALLS"
printf '\n' >> "$MOCK_CALLS"

output_file=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            output_file="$2"
            shift 2
            ;;
        -w|--write-out|--connect-timeout|--max-time|--retry)
            shift 2
            ;;
        -*)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

endpoint=${url##*/}
exit_file="${MOCK_HTTP_DIR}/${endpoint}.exit"
if [[ -f "$exit_file" ]]; then
    exit_code=$(<"$exit_file")
    if [[ "$exit_code" != "0" ]]; then
        if [[ -n "$output_file" ]]; then
            printf 'partial-sensitive-response' > "$output_file"
        fi
        exit "$exit_code"
    fi
fi

body_file="${MOCK_HTTP_DIR}/${endpoint}.body"
if [[ -n "$output_file" ]]; then
    if [[ -f "$body_file" ]]; then
        cp "$body_file" "$output_file"
    else
        : > "$output_file"
    fi
fi

code_file="${MOCK_HTTP_DIR}/${endpoint}.code"
if [[ -f "$code_file" ]]; then
    printf '%s' "$(<"$code_file")"
else
    printf '000'
fi
EOF

cat > "${mock_bin}/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "${mock_bin}/journalctl" <<'EOF'
#!/bin/bash
printf 'journalctl %s\n' "$*" >> "$MOCK_CALLS"
echo "Mock journal output"
exit 0
EOF

chmod +x "${mock_bin}/systemctl" "${mock_bin}/curl" "${mock_bin}/sleep" "${mock_bin}/journalctl"

write_enabled_config() {
    local listen="${1:-127.0.0.1:10085}"
    cat > "$config_file" <<EOF
Observability:
  Enable: true
  Listen: "$listen"
  ReadinessStaleAfter: 180
MachineConfig:
  Enable: true
  Token: "config-token-must-stay-private"
  Password: "config-password-must-stay-private"
EOF
}

write_disabled_config() {
    cat > "$config_file" <<'EOF'
Observability:
  Enable: false
  Listen: "127.0.0.1:10085"
MachineConfig:
  Token: "disabled-token-must-stay-private"
EOF
}

set_response() {
    local endpoint="$1"
    local code="$2"
    local body="$3"
    printf '%s' "$code" > "${mock_http}/${endpoint}.code"
    printf '%s' "$body" > "${mock_http}/${endpoint}.body"
    rm -f "${mock_http}/${endpoint}.exit"
}

set_timeout() {
    local endpoint="$1"
    printf '28' > "${mock_http}/${endpoint}.exit"
    rm -f "${mock_http}/${endpoint}.code" "${mock_http}/${endpoint}.body"
}

reset_http() {
    rm -f "${mock_http}"/*
    : > "$mock_calls"
}

set_default_metrics() {
    set_response metrics 200 'xrayrp_runtime_state{kind="machine",mode="machine",lifecycle="running",node_slot="",websocket="connected",failure_stage="none"} 1'
}

run_xrayr() {
    PATH="${mock_bin}:$PATH" \
    XRAYR_TEST_MODE=1 \
    XRAYR_CONFIG_FILE="$config_file" \
    XRAYR_SERVICE_FILE="$service_file" \
    MOCK_CALLS="$mock_calls" \
    MOCK_HTTP_DIR="$mock_http" \
    MOCK_SERVICE_ACTIVE=true \
    TMPDIR="$mock_tmp" \
    TZ=UTC \
    XRAYR_OBSERVABILITY_URL="${XRAYR_OBSERVABILITY_URL:-}" \
        bash "${repo_root}/XrayR.sh" "$@" 2>&1
}

write_enabled_config
reset_http
set_response livez 200 '{"status":"live"}'
set_response readyz 200 '{"status":"ready"}'
set_default_metrics
output=$(run_xrayr status)
assert_contains "$output" "系统服务：运行中" "status did not retain the systemd state"
assert_contains "$output" "程序存活：正常" "livez 200 was not shown as healthy"
assert_contains "$output" "节点就绪：正常" "readyz ready was not shown as ready"
assert_contains "$output" "WebSocket：已连接" "connected WebSocket metric was not shown"
assert_contains "$output" "拓扑版本：0" "missing topology metric did not use a safe zero default"
assert_contains "$output" "最后同步：暂无数据" "zero sync timestamp was not shown safely"
calls=$(<"$mock_calls")
assert_contains "$calls" "--connect-timeout 1" "curl connect timeout is missing"
assert_contains "$calls" "--max-time 3" "curl total timeout is missing"
assert_contains "$calls" "--retry 0" "curl retry bound is missing"
assert_contains "$calls" "/metrics" "metrics endpoint was not queried"

reset_http
set_response livez 503 '{"status":"shutdown"}'
set_response readyz 503 '{"status":"not_ready","reasons":["shutdown"]}'
set_default_metrics
output=$(run_xrayr status)
assert_contains "$output" "程序存活：正在关闭" "livez 503 was not shown as shutting down"
assert_contains "$output" "节点就绪：未就绪" "readyz not_ready was not shown"
assert_contains "$output" "程序正在关闭" "shutdown reason was not translated"

reset_http
set_response livez 200 '{"status":"live"}'
set_response readyz 200 '{"status":"degraded"}'
set_default_metrics
output=$(run_xrayr status)
assert_contains "$output" "节点就绪：降级" "readyz degraded was not shown"

reset_http
set_response livez 200 '{"status":"live"}'
set_response readyz 503 '{"status":"not_ready","reasons":["shutdown","lifecycle","cleanup_pending","sync_unavailable","sync_stale","certificate_expired","unknown-secret-reason"]}'
set_default_metrics
output=$(run_xrayr status)
for translated_reason in \
    "程序正在关闭" \
    "节点生命周期异常" \
    "资源等待清理" \
    "尚无成功同步" \
    "同步状态过期" \
    "证书已过期"; do
    assert_contains "$output" "$translated_reason" "readyz reason was not translated"
done
assert_not_contains "$output" "unknown-secret-reason" "unknown readiness reason was printed"

write_disabled_config
reset_http
output=$(run_xrayr status)
assert_contains "$output" "状态接口未启用" "disabled Observability was reported incorrectly"
assert_not_contains "$output" "节点就绪：未就绪" "disabled Observability was treated as node failure"
calls=$(<"$mock_calls")
assert_not_contains "$calls" "curl" "disabled Observability still called curl"

write_enabled_config
reset_http
set_timeout livez
output=$(run_xrayr status)
assert_contains "$output" "状态接口不可访问" "livez timeout was not handled"
remaining_tmp_files=$(find "$mock_tmp" -mindepth 1 -print -quit)
assert_equals "$remaining_tmp_files" "" "livez timeout left response files behind"

write_enabled_config "127.0.0.1:19090"
reset_http
set_response livez 200 '{"status":"live"}'
set_response readyz 200 '{"status":"ready"}'
set_default_metrics
output=$(run_xrayr status)
calls=$(<"$mock_calls")
assert_contains "$calls" "http://127.0.0.1:19090/livez" "custom Observability.Listen was ignored"

cat > "$config_file" <<'EOF'
Observability:
  Enable: true
  Listen: ""
EOF
reset_http
set_response livez 200 '{"status":"live"}'
set_response readyz 200 '{"status":"ready"}'
set_default_metrics
output=$(run_xrayr status)
calls=$(<"$mock_calls")
assert_contains "$calls" "http://127.0.0.1:10085/livez" "empty Observability.Listen did not use the XrayRP default"

XRAYR_OBSERVABILITY_URL="http://127.0.0.1:29090"
reset_http
output=$(run_xrayr status)
calls=$(<"$mock_calls")
assert_contains "$calls" "http://127.0.0.1:29090/livez" "XRAYR_OBSERVABILITY_URL did not override the config"
unset XRAYR_OBSERVABILITY_URL

write_enabled_config
reset_http
set_response livez 200 '{"status":"live"}'
set_response readyz 200 '{"status":"degraded"}'
metrics_payload=$(cat <<'EOF'
# HELP xrayrp_runtime_state bounded runtime state
xrayrp_live 1
xrayrp_ready{user_id="metrics-user-private"} 1
xrayrp_runtime_state{kind="machine",mode="machine",lifecycle="running",node_slot="",websocket="connected",failure_stage="none"} 1
xrayrp_runtime_state{kind="controller",mode="machine",lifecycle="running",node_slot="0",websocket="connected",failure_stage="none",token="metrics-token-private"} 1
xrayrp_runtime_state{kind="controller",mode="machine",lifecycle="reloading",node_slot="1",websocket="degraded",failure_stage="sync"} 1
xrayrp_topology_generation{node_slot=""} 12
xrayrp_topology_generation{node_slot="0"} 11
xrayrp_topology_generation{node_slot="1"} 12
xrayrp_last_successful_sync_timestamp_seconds{node_slot="0",failure_stage="none"} 1785673800
xrayrp_last_successful_sync_timestamp_seconds{node_slot="1",failure_stage="sync"} 1785670200
xrayrp_last_failure_timestamp_seconds{node_slot="0",failure_stage="none"} 0
xrayrp_last_failure_timestamp_seconds{node_slot="1",failure_stage="sync"} 1785561300
xrayrp_cleanup_pending{node_slot="0"} 1
xrayrp_cleanup_pending{node_slot="1"} 0
xrayrp_traffic_report_backlog{node_slot="0"} 2
xrayrp_traffic_report_backlog{node_slot="1"} 3
xrayrp_certificate_expiry_timestamp_seconds{node_slot="0"} 1790812800
xrayrp_certificate_expiry_timestamp_seconds{node_slot="1"} 1789430400
xrayrp_private_metric{password="metrics-password-private"} 999
EOF
)
set_response metrics 200 "$metrics_payload"
output=$(run_xrayr status)
assert_contains "$output" "WebSocket：降级" "multi-node WebSocket state was not aggregated"
assert_contains "$output" "拓扑版本：12" "multi-node topology generation was not aggregated"
assert_contains "$output" "最后同步：2026-08-02 12:30:00" "latest successful sync was not converted"
assert_contains "$output" "最后失败：2026-08-01 05:15:00" "latest failure was not converted"
assert_contains "$output" "最后失败阶段：同步" "latest failure stage was not shown"
assert_contains "$output" "待清理资源：1" "multi-node cleanup state was not aggregated"
assert_contains "$output" "流量上报积压：5" "multi-node traffic backlog was not aggregated"
assert_contains "$output" "证书到期：2026-09-15" "earliest certificate expiry was not selected"
assert_contains "$output" "运行状态：重新加载" "runtime lifecycle was not aggregated"
for secret in \
    "metrics-user-private" \
    "metrics-token-private" \
    "metrics-password-private" \
    "xrayrp_private_metric"; do
    assert_not_contains "$output" "$secret" "metrics output leaked an unknown metric or sensitive label"
done

reset_http
set_response livez 200 '{"status":"live"}'
set_response readyz 200 '{"status":"ready"}'
set_response metrics 200 'xrayrp_runtime_state{kind="machine",mode="machine",lifecycle="running",node_slot="",websocket="disabled",failure_stage="none"} 1
xrayrp_last_successful_sync_timestamp_seconds{node_slot=""} 0
xrayrp_last_failure_timestamp_seconds{node_slot="",failure_stage="none"} 0
xrayrp_certificate_expiry_timestamp_seconds{node_slot=""} 0'
output=$(run_xrayr status)
assert_contains "$output" "WebSocket：未启用" "disabled WebSocket metric was not shown"
assert_contains "$output" "最后同步：暂无数据" "zero sync timestamp was not handled"
assert_contains "$output" "最后失败：暂无数据" "zero failure timestamp was not handled"
assert_contains "$output" "最后失败阶段：无" "empty failure stage was not handled"
assert_contains "$output" "证书到期：暂无数据" "zero certificate timestamp was not handled"

reset_http
set_response livez 200 '{"status":"live"}'
set_response readyz 200 '{"status":"ready"}'
set_timeout metrics
output=$(run_xrayr status)
assert_contains "$output" "详细运行状态：不可用" "metrics timeout was not isolated"

write_enabled_config
reset_http
set_response livez 200 '{"status":"unexpected","Token":"response-token-must-stay-private","Password":"response-password-must-stay-private"}'
output=$(run_xrayr status)
assert_contains "$output" "状态接口不可访问" "unexpected livez payload was not bounded"
for secret in \
    "response-token-must-stay-private" \
    "response-password-must-stay-private" \
    "config-token-must-stay-private" \
    "config-password-must-stay-private"; do
    assert_not_contains "$output" "$secret" "status output leaked sensitive data"
done

for management_command in start stop restart log; do
    reset_http
    output=$(run_xrayr "$management_command")
    assert_not_contains "$output" "状态接口不可访问" "interface state affected the ${management_command} command"
    calls=$(<"$mock_calls")
    assert_not_contains "$calls" "curl" "${management_command} command unexpectedly queried Observability"
done

echo "PASS: livez and readyz status"
