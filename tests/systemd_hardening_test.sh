#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
service="$repo_root/XrayR.service"
fail(){ echo "FAIL: $*" >&2; exit 1; }
for required in 'User=xrayr' 'Group=xrayr' 'NoNewPrivileges=true' 'PrivateTmp=true' 'PrivateDevices=true' 'ProtectHome=true' 'ProtectSystem=strict' 'ProtectKernelTunables=true' 'ProtectKernelModules=true' 'ProtectControlGroups=true' 'RestrictSUIDSGID=true' 'LimitCORE=0'; do
  grep -qF -- "$required" "$service" || fail "missing $required"
done
if grep -qE '^User=root$|^Group=root$|^LimitCORE=infinity$' "$service"; then fail 'service still runs with root/unlimited core dumps'; fi
if grep -qE '^User=root$|^Group=root$' "$repo_root/install-machine.sh"; then fail 'installer still emits root service'; fi
if grep -qF 'cat > "$service_file"' "$repo_root/install-machine.sh"; then fail 'installer still embeds service template'; fi
if command -v systemd-analyze >/dev/null 2>&1; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/xrayr-systemd.XXXXXX")
  trap 'rm -rf -- "$tmp"' EXIT
  mkdir -p "$tmp/usr/local/XrayR" "$tmp/etc/XrayR"
  sed -e 's#WorkingDirectory=/usr/local/XrayR/#WorkingDirectory=/tmp#' \
      -e 's#ExecStart=/usr/local/XrayR/XrayR --config /etc/XrayR/config.yml#ExecStart=/bin/true#' \
      "$repo_root/XrayR.service" > "$tmp/XrayR.service"
  systemd-analyze verify "$tmp/XrayR.service" 2>"$tmp/verify.err" || { cat "$tmp/verify.err" >&2; fail 'systemd-analyze verify failed'; }
fi
echo 'PASS: systemd service hardening'
