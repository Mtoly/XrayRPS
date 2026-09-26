#!/bin/bash

set -euo pipefail

# shellcheck source=test_helper.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

installer="${repo_root}/install-machine.sh"
pty_runner="${repo_root}/tests/pty_run.py"

require_tools() {
    local tool
    for tool in python3 setsid timeout; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "SKIP: interactive prompt tests need ${tool}" >&2
            exit 0
        }
    done
}

run_pty() {
    local plan_file="$1"
    shift
    python3 "$pty_runner" --timeout 25 "$@" < "$plan_file"
}

require_tools

work_dir=$(new_temp_dir)
trap 'remove_temp_dir "$work_dir"' EXIT

# 1. A complete command line must never prompt, even inside a terminal.
cat > "${work_dir}/complete.plan" <<EOF
expect-not API Host:
expect-not Machine ID:
expect-not Machine Token:
run bash "${installer}" --api-host https://panel.example.com --machine-id 1 --token pty-complete-token --dry-run
EOF
if ! complete_output=$(run_pty "${work_dir}/complete.plan" 2>&1); then
    fail "complete CLI arguments were rejected or prompted inside a terminal: ${complete_output}"
fi
assert_contains "$complete_output" "Token=[redacted]" "complete CLI dry run did not redact the token"
assert_not_contains "$complete_output" "pty-complete-token" "complete CLI dry run leaked the token"
echo "PASS: complete CLI arguments never prompt"

# 1b. --help must stay non-interactive as well.
cat > "${work_dir}/help.plan" <<EOF
expect-not API Host:
expect-not Machine ID:
expect-not Machine Token:
expect XrayRP Xboard machine-mode installer
run bash "${installer}" --help
EOF
help_output=$(run_pty "${work_dir}/help.plan" 2>&1) || fail "--help prompted instead of printing usage: ${help_output}"
assert_contains "$help_output" "Interactive example:" "usage does not document the interactive flow"
assert_contains "$help_output" "Non-interactive example:" "usage does not document the non-interactive flow"
echo "PASS: --help stays non-interactive"

# 2. A bare invocation prompts for every required value.
cat > "${work_dir}/all-prompt.plan" <<EOF
expect API Host:
send
expect A value is required for API Host.
send https://panel.example.com
expect Machine ID:
send 42
secret Machine Token:
send pty-all-secret-token
expect Token=[redacted]
run bash "${installer}" --dry-run
EOF
if ! all_output=$(run_pty "${work_dir}/all-prompt.plan" 2>&1); then
    fail "bare interactive install did not complete: ${all_output}"
fi
assert_not_contains "$all_output" "pty-all-secret-token" "interactive token was echoed or logged"
assert_contains "$all_output" "MachineID=42" "interactive machine-id was not applied"
assert_contains "$all_output" "ApiHost=https://panel.example.com" "interactive api-host was not applied"
assert_contains "$all_output" "PanelType=NewV2board" "default panel type changed"
assert_contains "$all_output" "WebSocket=true" "default websocket setting changed"
echo "PASS: missing required values are prompted for and applied"

# 3. Values supplied on the command line must not be asked for again.
cat > "${work_dir}/partial.plan" <<EOF
expect-not API Host:
expect Machine ID:
send 7
secret Machine Token:
send pty-partial-secret-token
run bash "${installer}" --api-host https://panel.example.com --dry-run
EOF
partial_output=$(run_pty "${work_dir}/partial.plan" 2>&1) || fail "partial interactive install failed: ${partial_output}"
assert_not_contains "$partial_output" "API Host:" "api-host was asked for although it was passed on the command line"
assert_not_contains "$partial_output" "pty-partial-secret-token" "partial install leaked the token"
assert_contains "$partial_output" "MachineID=7" "prompted machine-id was not applied"
echo "PASS: only missing values are prompted for"

# 4. A pipe without a controlling terminal must not prompt or hang.
no_tty_status=0
no_tty_output=$(setsid -w timeout 25 bash "$installer" --api-host https://panel.example.com < /dev/null 2>&1) ||
    no_tty_status=$?
assert_equals "$no_tty_status" "1" "non-TTY run did not fail with the validation error"
assert_contains "$no_tty_output" -- "--machine-id is required" "non-TTY run did not report the missing machine-id"
assert_not_contains "$no_tty_output" "API Host:" "non-TTY run prompted for api-host"
assert_not_contains "$no_tty_output" "Machine ID:" "non-TTY run prompted for machine-id"
assert_not_contains "$no_tty_output" "Machine Token:" "non-TTY run prompted for token"
echo "PASS: non-TTY runs never prompt and still fail validation"

# 5. A terminal without /dev/tty access (CI without a controlling terminal)
#    must behave exactly like a non-interactive run.
detached_error="${work_dir}/detached.error"
detached_status=0
detached_output=$(setsid -w bash "$installer" --api-host https://panel.example.com < /dev/null 2>&1) ||
    detached_status=$?
assert_equals "$detached_status" "1" "detached run did not fail with the validation error"
assert_contains "$detached_output" -- "--machine-id is required" "detached run did not report the missing machine-id"
assert_not_contains "$detached_output" "API Host:" "detached run prompted for api-host"

if setsid -w bash -c "true < /dev/tty > /dev/tty" 2>"$detached_error"; then
    fail "test environment still provides /dev/tty while detached"
fi
grep -qi "No such device or address" "$detached_error" || \
    fail "detached run did not fail on /dev/tty as expected: $(cat "$detached_error")"
echo "PASS: missing /dev/tty access stays non-interactive"

# 6. Unattended usage keeps the original CLI contract.
unattended_token="pty-unattended-token"
unattended_output=$(timeout 25 bash "$installer" \
    --api-host https://panel.example.com \
    --machine-id 1 \
    --token "$unattended_token" \
    --panel-type NewV2board \
    --enable-ws \
    --dry-run 2>&1)
assert_not_contains "$unattended_output" "$unattended_token" "unattended install leaked the token"
assert_contains "$unattended_output" "Dry run: no files will be written" "unattended install did not reach the dry run"
assert_contains "$unattended_output" "PanelType=NewV2board" "unattended panel type was not applied"
assert_contains "$unattended_output" "WebSocket=true" "unattended websocket flag was not applied"
echo "PASS: existing unattended CLI usage is unchanged"

# 7. Wrapping the script in a pipe must still prompt through /dev/tty, so
#    "cat install-machine.sh | bash -s -- <args>" keeps working interactively.
cat > "${work_dir}/piped.plan" <<EOF
expect-not API Host:
expect Machine ID:
send 9
secret Machine Token:
send pty-piped-secret-token
expect Dry run: no files will be written
run bash -c 'cat "${repo_root}/install-machine.sh" | bash -s -- --api-host https://panel.example.com --dry-run'
EOF
piped_output=$(run_pty "${work_dir}/piped.plan" 2>&1) || fail "piped install did not complete interactively: ${piped_output}"
assert_not_contains "$piped_output" "API Host:" "piped install asked for api-host although it was passed as an argument"
assert_not_contains "$piped_output" "pty-piped-secret-token" "piped install leaked the token"
assert_contains "$piped_output" "MachineID=9" "piped install did not apply the prompted machine-id"
assert_contains "$piped_output" "ApiHost=https://panel.example.com" "piped install did not apply the api-host argument"
echo "PASS: piped script still prompts through /dev/tty"

echo "PASS: interactive machine installer prompts"
