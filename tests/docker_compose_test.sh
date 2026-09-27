#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail(){ echo "FAIL: $*" >&2; exit 1; }
compose="$repo_root/docker-compose.yml"
if grep -qF 'ghcr.io/mtoly/xrayr:' "$compose"; then fail 'compose references the retired xrayr package name'; fi
grep -qE '^[[:space:]]+pull_policy:[[:space:]]+always[[:space:]]*$' "$compose" || fail 'pull_policy: always missing'
grep -qF 'read_only: true' "$compose" || fail 'read-only filesystem missing'
grep -qF 'no-new-privileges:true' "$compose" || fail 'no-new-privileges missing'
grep -qF '      - ALL' "$compose" || fail 'capability drop missing'
grep -qF 'healthcheck:' "$compose" || fail 'healthcheck missing'
grep -qF 'mem_limit:' "$compose" || fail 'memory limit missing'
grep -qF 'cpus:' "$compose" || fail 'CPU limit missing'
if command -v docker >/dev/null 2>&1; then
  env -u XRAYRP_TAG docker compose -f "$compose" config >/dev/null
  default_image=$(env -u XRAYRP_TAG docker compose -f "$compose" config --images)
  [ "$default_image" = 'ghcr.io/mtoly/xrayrp:latest' ] || fail "default image resolved to $default_image instead of ghcr.io/mtoly/xrayrp:latest"
  pinned_image=$(XRAYRP_TAG=0.9.1-alpha-6 docker compose -f "$compose" config --images)
  [ "$pinned_image" = 'ghcr.io/mtoly/xrayrp:0.9.1-alpha-6' ] || fail "XRAYRP_TAG=0.9.1-alpha-6 resolved to $pinned_image instead of ghcr.io/mtoly/xrayrp:0.9.1-alpha-6"
else
  # Without Docker, assert the same contract statically.
  grep -qF 'image: ghcr.io/mtoly/xrayrp:${XRAYRP_TAG:-latest}' "$compose" || fail 'image does not default to the latest XrayRP release with an XRAYRP_TAG override'
fi
echo 'PASS: Docker Compose hardening'
