# Changelog

## Unreleased - 2026-09-12
### Fixed

- Restore `XrayR.service` to `User=root` and `Group=root` after the dedicated `xrayr` account rollout caused `status=217/USER` on incomplete upgrades and low-port bind failures for machine nodes using TCP 80/443.
- Remove dedicated service-account provisioning and all installer dependencies on the `xrayr` user and group. Existing accounts are intentionally left untouched.
- Restore `/usr/local/XrayR`, `/etc/XrayR`, and `/var/lib/xrayr` ownership to `root:root` without deleting or replacing existing configuration, certificates, or state data.
- Keep the existing systemd sandboxing controls and continue to run `systemctl daemon-reload` before service restart.

### Tests

- Cover fresh installs, historical root-service upgrades, upgrades from the dedicated-account unit, hosts with and without an existing `xrayr` account, repeated installation, machine mode, root ownership repair, preserved configuration/certificates/state, and TCP 80/443 binding under the root service identity.
