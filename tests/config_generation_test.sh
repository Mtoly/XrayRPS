#!/bin/bash

set -euo pipefail

# shellcheck source=test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"
# shellcheck source=../install-machine.sh
source "${repo_root}/install-machine.sh"

test_dir=$(new_temp_dir)
trap 'remove_temp_dir "$test_dir"' EXIT

set_installer_values() {
    local target_dir="$1"

    config_dir="$target_dir"
    config_file="${config_dir}/config.yml"
    api_host="https://panel.example.com"
    panel_type="NewV2board"
    machine_id="7"
    token="machine-token-should-never-be-logged"
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
}

default_dir="${test_dir}/default"
set_installer_values "$default_dir"
default_output=$(write_machine_config 2>&1)
assert_not_contains "$default_output" "$token" "new config generation leaked the machine token"
assert_contains "$(cat "$config_file")" "Observability:" "Observability section was not generated"
assert_contains "$(cat "$config_file")" "Listen: \"127.0.0.1:10085\"" "default observability listen was not generated"
assert_contains "$(cat "$config_file")" "ReadinessStaleAfter: 180" "default readiness staleness was not generated"
assert_contains "$(cat "$config_file")" "WebSocketConfig:" "WebSocketConfig was not generated"
assert_equals "$(stat -c "%a" "$config_file")" "600" "generated config does not have mode 600"

preserved_dir="${test_dir}/preserved"
mkdir -p "$preserved_dir"
cat > "${preserved_dir}/config.yml" <<'EOF'
Observability:
  Enable: false
  Listen: "127.0.0.1:19090"
  ReadinessStaleAfter: 420
MachineConfig:
  Enable: true
  Token: "old-token-that-must-not-be-logged"
EOF

set_installer_values "$preserved_dir"
force="true"
preserved_output=$(write_machine_config 2>&1)
assert_not_contains "$preserved_output" "old-token-that-must-not-be-logged" "config update leaked the old token"
assert_not_contains "$preserved_output" "$token" "config update leaked the new token"
assert_contains "$(cat "$config_file")" "Enable: false" "existing Observability.Enable was not preserved"
assert_contains "$(cat "$config_file")" "Listen: \"127.0.0.1:19090\"" "existing Observability.Listen was not preserved"
assert_contains "$(cat "$config_file")" "ReadinessStaleAfter: 420" "existing ReadinessStaleAfter was not preserved"

dry_run_token="dry-run-token-must-stay-private"
dry_run_output=$(bash "${repo_root}/install-machine.sh" \
    --api-host "https://panel.example.com" \
    --machine-id 7 \
    --token "$dry_run_token" \
    --dry-run 2>&1)
assert_not_contains "$dry_run_output" "$dry_run_token" "installer dry run leaked the machine token"
assert_contains "$dry_run_output" "Token=[redacted]" "installer dry run did not mark the token as redacted"

echo "PASS: machine config generation"
