# Veeam Hardened Repository Safe Bootstrap

A Bash script that prepares an Ubuntu `22.04 LTS` or `24.04 LTS` server as a `Veeam Hardened Repository`, using a safer two-phase workflow:

1. `prepare`
Sets up the server for the first Veeam connection.

2. `post-attach-lockdown`
Reduces the privileges of the `veeamrepo` user only after the first successful onboarding.

## Why This Script Exists

Many hardened repository scripts are either too aggressive or too opaque:

- they assume the repository disk is always `/dev/sdb`
- they remove privileges too early
- they overwrite system configuration too aggressively
- they do not help the operator choose the right parameters

This project aims for the opposite:

- safety first
- guided behavior where possible
- dry-run and precheck support
- practical operational documentation
- a GitHub repository that is understandable even for users with limited Linux experience

## What It Does

The script:

- prepares the repository disk with LVM and XFS
- configures persistent mount and repository path
- creates or prepares the `veeamrepo` user
- keeps temporary `sudo` access during the first Veeam onboarding
- configures SSH, UFW, logging, audit, and baseline hardening
- applies the final user lock-down only after the first attach

## What It Does Not Do

The script does not:

- make destructive guesses when disk selection is ambiguous
- remove `veeamrepo` privileges too early
- require `.env` files or external configuration files

## Supported Systems

- Ubuntu `22.04 LTS`
- Ubuntu `24.04 LTS`

## Repository Structure

- [veeam_hardened_repository_safe.sh](./veeam_hardened_repository_safe.sh)
- [docs/OPERATIONAL_GUIDE.md](./docs/OPERATIONAL_GUIDE.md)
- [CHANGELOG.md](./CHANGELOG.md)
- [CONTRIBUTING.md](./CONTRIBUTING.md)
- [PUBLISHING_CHECKLIST.md](./PUBLISHING_CHECKLIST.md)

## Quick Start

### 1. Show help

```bash
bash veeam_hardened_repository_safe.sh --help
```

### 2. Simulate the run

```bash
sudo bash veeam_hardened_repository_safe.sh \
  --dry-run \
  --non-interactive \
  --phase prepare \
  --disk /dev/sdb \
  --mount /veeamrepo \
  --repo-dir /veeamrepo/backup \
  --veeam-user veeamrepo \
  --veeam-group veeamrepo \
  --ssh-net 192.168.10.0/24 \
  --veeam-net 192.168.10.0/24
```

### 3. Run prechecks

```bash
sudo bash veeam_hardened_repository_safe.sh \
  --precheck-only \
  --non-interactive \
  --phase prepare \
  --disk /dev/sdb \
  --mount /veeamrepo \
  --repo-dir /veeamrepo/backup \
  --veeam-user veeamrepo \
  --veeam-group veeamrepo \
  --ssh-net 192.168.10.0/24 \
  --veeam-net 192.168.10.0/24
```

### 4. Run the preparation phase

```bash
sudo bash veeam_hardened_repository_safe.sh \
  --non-interactive \
  --phase prepare \
  --disk /dev/sdb \
  --mount /veeamrepo \
  --repo-dir /veeamrepo/backup \
  --veeam-user veeamrepo \
  --veeam-group veeamrepo \
  --ssh-net 192.168.10.0/24 \
  --veeam-net 192.168.10.0/24
```

### 5. After Veeam onboarding, apply the lock-down

```bash
sudo bash veeam_hardened_repository_safe.sh \
  --phase post-attach-lockdown \
  --veeam-user veeamrepo \
  --veeam-group veeamrepo
```

## Multiple Networks

If you need to allow multiple networks, use a single argument with comma-separated values.

Correct:

```bash
--ssh-net 192.168.10.0/24,192.168.20.0/24
--veeam-net 10.10.50.0/24,10.10.60.0/24
```

Incorrect:

```bash
--ssh-net 192.168.10.0/24 --ssh-net 192.168.20.0/24
```

In that case only the last value is kept.

## Before Using `--force-wipe yes`

Always check:

```bash
lsblk -f /dev/sdb
wipefs -n /dev/sdb
findmnt /
```

If you are not fully sure about the disk, stop.

## Documentation

For operational use:

- [docs/OPERATIONAL_GUIDE.md](./docs/OPERATIONAL_GUIDE.md)

## Project Status

The project is ready for operational use and further iteration.

If you plan to distribute or reuse it widely, add an explicit `LICENSE` file.

## GitHub Publishing

Use the checklist:

- [PUBLISHING_CHECKLIST.md](./PUBLISHING_CHECKLIST.md)

## Important Notes

- do not run lock-down before the first successful onboarding
- do not use `--force-wipe yes` without validating the disk first
- always try `dry-run` and `precheck-only` first
