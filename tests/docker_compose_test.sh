#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail(){ echo "FAIL: $*" >&2; exit 1; }
compose="$repo_root/docker-compose.yml"
grep -qF 'image: ghcr.io/Mtoly/xrayr:0.9.1-alpha-6' "$compose" || fail 'image is not pinned to a reviewed release tag'
if grep -qE 'image: .*:latest$' "$compose"; then fail 'compose still tracks latest'; fi
grep -qF 'read_only: true' "$compose" || fail 'read-only filesystem missing'
grep -qF 'no-new-privileges:true' "$compose" || fail 'no-new-privileges missing'
grep -qF '      - ALL' "$compose" || fail 'capability drop missing'
grep -qF 'healthcheck:' "$compose" || fail 'healthcheck missing'
grep -qF 'mem_limit:' "$compose" || fail 'memory limit missing'
grep -qF 'cpus:' "$compose" || fail 'CPU limit missing'
if command -v docker >/dev/null 2>&1; then
  docker compose -f "$compose" config >/dev/null
fi
echo 'PASS: Docker Compose hardening'
