#!/bin/bash

set -euo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

bash "${tests_dir}/config_generation_test.sh"
bash "${tests_dir}/status_test.sh"
bash "${tests_dir}/systemd_hardening_test.sh"
bash "${tests_dir}/config_defaults_test.sh"
bash "${tests_dir}/docker_compose_test.sh"
bash "${tests_dir}/service_account_test.sh"
