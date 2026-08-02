#!/bin/bash

set -euo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

bash "${tests_dir}/config_generation_test.sh"
bash "${tests_dir}/status_test.sh"
