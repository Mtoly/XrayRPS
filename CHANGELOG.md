# Changelog

## Unreleased - 2026-09-12

### Fixed

- Provision and verify the `xrayr` system user and group before installing or starting `XrayR.service` on both standard and machine-mode installs.
- Repair partial account states where only the `xrayr` user or group exists, with compatible `useradd`/`groupadd`, Debian-style `adduser`/`addgroup`, and Alpine BusyBox commands.
- Stop and roll back the release installation when service-account creation or permission setup fails instead of continuing to a `status=217/USER` restart loop.
- Apply service-readable ownership and permissions to `/usr/local/XrayR`, `/etc/XrayR` (including certificate subdirectories), and `/var/lib/xrayr` while preserving existing configuration files.
- Reload systemd after updating `XrayR.service` and before enabling or starting the service.

### Tests

- Add regression coverage for new installs, upgrades from the historical root-run service, complete and partial account states, creation failures, repeated idempotent runs, supported account-management command families, directory permissions, startup ordering, and the `217/USER` failure condition.
