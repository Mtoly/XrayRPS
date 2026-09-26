# Changelog

## Unreleased - 2026-09-12

### Added

- Prompt interactively for `--api-host`, `--machine-id`, and `--token` in `install-machine.sh` when a controlling terminal is available and those options are not supplied. The token is read without echo and is never printed or logged.
- Keep non-interactive runs unchanged: without a controlling terminal the prompt step is skipped, `validate_args` still reports the first missing option, and all existing CLI invocations behave as before.
- Allow `install-machine.sh` to run when it is fed to bash through stdin (`bash -s -- <options>`); previously `set -u` aborted on the unset `BASH_SOURCE` lookup.

### Fixed

- Restore `XrayR.service` to `User=root` and `Group=root` after the dedicated `xrayr` account rollout caused `status=217/USER` on incomplete upgrades and low-port bind failures for machine nodes using TCP 80/443.
- Remove dedicated service-account provisioning and all installer dependencies on the `xrayr` user and group. Existing accounts are intentionally left untouched.
- Restore `/usr/local/XrayR`, `/etc/XrayR`, and `/var/lib/xrayr` ownership to `root:root` without deleting or replacing existing configuration, certificates, or state data.
- Keep the existing systemd sandboxing controls and continue to run `systemctl daemon-reload` before service restart.

### Tests

- Cover fresh installs, historical root-service upgrades, upgrades from the dedicated-account unit, hosts with and without an existing `xrayr` account, repeated installation, machine mode, root ownership repair, preserved configuration/certificates/state, and TCP 80/443 binding under the root service identity.
- Cover interactive prompting through a real pseudo-terminal: complete CLI arguments never prompt, missing values are collected from prompts, the token stays hidden and out of captured output, and non-interactive runs without a controlling terminal never block.
