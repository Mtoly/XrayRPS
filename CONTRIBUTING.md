# Contributing

## Before opening a pull request

1. Keep each pull request focused on one concern and independently reversible.
2. Never commit credentials, private keys, certificates, generated logs, or local machine paths.
3. Run shell syntax checks and the relevant tests from `tests/`.
4. Run `git diff --check` and review the complete diff for unintended files.
5. For installer changes, test failure behavior and verify that the previous installation remains recoverable.
6. For service or container changes, validate the unit or Compose file with the available local tooling.

## Pull request expectations

Describe the motivation, affected files, security impact, compatibility considerations, and exact validation commands. Use a separate branch for each change. Do not merge deployment or release changes without a maintainer review.

## Configuration and secrets

Use placeholders in examples and inject real values at deployment time. Keep local overrides outside version control. If a secret is accidentally committed, rotate it immediately and report the incident privately using the process in `SECURITY.md`.