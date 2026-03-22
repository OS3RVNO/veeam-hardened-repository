# Security Policy

## Supported Scope

Security-related issues are relevant when they affect:

- destructive disk handling
- privilege management for `veeamrepo`
- SSH hardening behavior
- firewall behavior
- unsafe command execution or input handling

## Reporting

If you believe you found a security issue in this project, avoid posting full exploit details in a public issue immediately.

Instead, open an issue with a minimal description and clearly mark it as security-related, or share a reduced reproduction that does not expose secrets or production details.

## Notes

- always test in a lab before production use
- always use `--dry-run` and `--precheck-only` before destructive operations
- review the script carefully before running `--force-wipe yes`
