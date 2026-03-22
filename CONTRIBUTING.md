# Contributing

Thanks for your interest in this project.

## Before Proposing Changes

Always verify:

```bash
bash -n veeam_hardened_repository_safe.sh
bash veeam_hardened_repository_safe.sh --help
bash veeam_hardened_repository_safe.sh --help-full
```

If you touch destructive logic or storage behavior:

- do not test on production systems
- use a lab host
- try `--dry-run` first

## Guidelines

- do not introduce implicit destructive behavior
- keep the two-phase workflow intact
- avoid unnecessary external dependencies
- document new parameters in the README and operational guide
