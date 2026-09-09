#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail(){ echo "FAIL: $*" >&2; exit 1; }
jq -e \
  '.[0].listen == "127.0.0.1" and .[0].settings.auth == "password" and .[0].settings.accounts[0].user == "CHANGE_ME" and .[0].settings.accounts[0].pass == "CHANGE_ME"' \
  "$repo_root/config/custom_inbound.json" >/dev/null || fail 'custom inbound defaults are not localhost/password protected'
if grep -R -nE 'ApiKey: "123"|RedisPassword: YOUR PASSWORD|PrivateKey: YOUR_PRIVATE_KEY' "$repo_root/config/config.yml"; then
  fail 'default configuration still contains directly reusable example credentials'
fi
source "$repo_root/install-machine.sh"
api_host=https://panel.example.com
machine_id=7
token=machine-token
panel_type=NewV2board
timeout=30
discovery_interval=60
heartbeat_interval=30
reconnect_backoff=5
resync_on_reconnect=true
version=latest
listen_ip=127.0.0.1
send_ip=::1
validate_args
[[ "$listen_ip" == 127.0.0.1 && "$send_ip" == ::1 ]] || fail 'valid IPv4/IPv6 values were rejected or changed'
for bad in 999.1.1.1 10.0.0 invalid; do
  listen_ip="$bad"
  if (validate_args) >/dev/null 2>&1; then fail "invalid IP accepted: $bad"; fi
done
grep -qF 'config_file="${XRAYR_CONFIG_FILE:-/etc/XrayR/config.yml}"' "$repo_root/XrayR.sh" || fail 'config override variable is missing'
if grep -nF 'vi /etc/XrayR/config.yml' "$repo_root/XrayR.sh"; then fail 'management script still hardcodes config path'; fi
grep -qF 'vi "$config_file"' "$repo_root/XrayR.sh" || fail 'management script does not use configured config path'
echo 'PASS: secure configuration defaults and input validation'
