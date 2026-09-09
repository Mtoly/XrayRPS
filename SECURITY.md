# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately to the repository maintainers before opening a public issue. Include:

- affected version, commit, or deployment method;
- reproducible steps and expected versus observed behavior;
- impact assessment and any relevant logs or configuration excerpts.

Remove tokens, API keys, private keys, certificates, and personal data before sending evidence. Do not include live credentials in issues, pull requests, sample configurations, or test fixtures.

## Supported versions

Security fixes target the maintained default branch and the newest reviewed release. Operators should pin a release and retain its checksum record rather than deploying a mutable `latest` tag.

## Deployment baseline

- Download installers and release metadata over HTTPS with certificate validation enabled.
- Verify release archives against the matching `SHA256SUMS` file before activation.
- Run the systemd unit as the dedicated `xrayr` account with the sandboxing options in `XrayR.service`.
- Mount container configuration read-only, pin the image tag, drop capabilities, and enable no-new-privileges.
- Keep custom inbounds on loopback until authentication, ports, and exposure have been reviewed.
- Back up configuration and retain the previous installation during upgrades.

## Disclosure

Maintainers will coordinate a fix, document affected versions, and publish remediation guidance when the issue is ready for disclosure.