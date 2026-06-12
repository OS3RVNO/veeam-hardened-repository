# Operational Guide

Reference script: [veeam_hardened_repository_safe.sh](../veeam_hardened_repository_safe.sh)

## Purpose

This script prepares an Ubuntu `22.04 LTS` or `24.04 LTS` server as a `Veeam Hardened Repository`.

It works in two phases:

1. `prepare`
Prepares the server for the first Veeam connection.

2. `post-attach-lockdown`
Reduces the privileges of the `veeamrepo` user only after the repository has been successfully added in Veeam.

## Important Rule

Do not run `post-attach-lockdown` before the first successful Veeam onboarding.

During the first connection, `veeamrepo` must still be able to elevate privileges.

## Recommended Sequence

1. `dry-run`
2. `precheck-only`
3. `prepare`
4. add the repository in Veeam
5. run a backup test
6. `post-attach-lockdown`
7. run a restore test after lockdown
8. remove the generated credential file after acceptance

For the complete production gate, use
[PRODUCTION_CHECKLIST.md](./PRODUCTION_CHECKLIST.md).

## Useful Commands Before You Start

### Show disks

```bash
lsblk -d -o NAME,SIZE,MODEL,TYPE
```

### Show filesystems and mounts

```bash
lsblk -f
```

### Identify the system disk

```bash
findmnt /
lsblk -no PKNAME "$(findmnt -n -o SOURCE /)"
```

### Check partitions and signatures on the target disk

Replace `/dev/sdb` with the correct disk.

```bash
lsblk -f /dev/sdb
wipefs -n /dev/sdb
```

### Check whether a path is already mounted

```bash
findmnt /veeamrepo
```

### Check whether the disk already has LVM metadata

```bash
pvs
vgs
lvs
```

## How to Choose the Correct Disk

Choose the repository disk using these rules:

- it must be dedicated to backup storage
- it must not be the operating system disk
- it must not contain data you need to keep
- its size must match your repository sizing plan

Useful commands:

```bash
lsblk -d -o NAME,SIZE,MODEL,SERIAL
findmnt /
lsblk -f
```

If you are unsure about the disk:

- stop
- do not use `--force-wipe yes`

## How to Choose `--mount`

Recommended value:

```bash
--mount /veeamrepo
```

The mount point is the directory where the repository filesystem will be mounted.

Use a short, dedicated path.

## How to Choose `--repo-dir`

Recommended value:

```bash
--repo-dir /veeamrepo/backup
```

Rules:

- it must be under the mount point
- it must be the path you will use in Veeam

Quick check:

```bash
echo /veeamrepo/backup
```

It must clearly be under `/veeamrepo`.

## How to Choose `--ssh-net`

`--ssh-net` defines which networks are allowed to administer the Linux server over SSH.

Example:

```bash
--ssh-net 192.168.10.0/24
```

If you need to allow multiple networks, pass them in the same argument separated by commas:

```bash
--ssh-net 192.168.10.0/24,192.168.20.0/24
```

Correct format:

- one option
- one or more CIDRs separated by commas
- no line breaks inside the value

Valid examples:

```bash
--ssh-net 192.168.10.0/24
--ssh-net 192.168.10.10/32
--ssh-net 192.168.10.0/24,192.168.20.0/24
```

Do not use:

```bash
--ssh-net 192.168.10.0/24 --ssh-net 192.168.20.0/24
```

In that case the script keeps only the last value.

If you are unsure, check which network is used to manage Linux or infrastructure servers.

Useful commands:

```bash
ip a
ip route
ss -tulpn
```

## How to Choose `--veeam-net`

`--veeam-net` defines which networks are allowed to reach the repository from Veeam.

Example:

```bash
--veeam-net 192.168.10.0/24
```

If you need to allow multiple networks, use the same comma-separated format:

```bash
--veeam-net 192.168.10.0/24,192.168.20.0/24
```

Valid examples:

```bash
--veeam-net 192.168.10.0/24
--veeam-net 10.10.50.0/24,10.10.60.0/24
```

Do not use:

```bash
--veeam-net 10.10.50.0/24 --veeam-net 10.10.60.0/24
```

Again, only the last value would be kept.

If the Veeam network is the same as the management network, you can use the same value as `--ssh-net`.

## When to Use `--force-wipe yes`

Use `--force-wipe yes` only when:

- the disk is correct
- the disk can be erased
- you know it contains old signatures or partitions you want to remove

Commands to help you decide:

```bash
lsblk -f /dev/sdb
wipefs -n /dev/sdb
```

If you see old filesystems or signatures and want to reuse the disk from scratch, `--force-wipe yes` is appropriate.

If you are not sure, do not use it.

## Standard Execution

### 1. Help

```bash
bash ./veeam_hardened_repository_safe.sh --help
```

### 2. Dry-run

```bash
sudo bash ./veeam_hardened_repository_safe.sh \
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

### Example with Multiple Allowed Networks

```bash
sudo bash ./veeam_hardened_repository_safe.sh \
  --dry-run \
  --non-interactive \
  --phase prepare \
  --disk /dev/sdb \
  --mount /veeamrepo \
  --repo-dir /veeamrepo/backup \
  --veeam-user veeamrepo \
  --veeam-group veeamrepo \
  --ssh-net 192.168.10.0/24,192.168.20.0/24 \
  --veeam-net 10.10.50.0/24,10.10.60.0/24
```

### 3. Precheck

```bash
sudo bash ./veeam_hardened_repository_safe.sh \
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

### 4. Prepare

```bash
sudo bash ./veeam_hardened_repository_safe.sh \
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

### 5. Prepare with Disk Wipe

```bash
sudo bash ./veeam_hardened_repository_safe.sh \
  --non-interactive \
  --phase prepare \
  --disk /dev/sdb \
  --force-wipe yes \
  --mount /veeamrepo \
  --repo-dir /veeamrepo/backup \
  --veeam-user veeamrepo \
  --veeam-group veeamrepo \
  --ssh-net 192.168.10.0/24 \
  --veeam-net 192.168.10.0/24
```

## What to Check After `prepare`

### Verify mount and filesystem

```bash
findmnt /veeamrepo
xfs_info /veeamrepo
df -h /veeamrepo
```

### Verify repository directory

```bash
ls -ld /veeamrepo
ls -ld /veeamrepo/backup
```

Expected result:

- `/veeamrepo` exists
- `/veeamrepo/backup` exists
- the backup directory is owned by `veeamrepo`

### Verify the `veeamrepo` user

```bash
id veeamrepo
getent passwd veeamrepo
groups veeamrepo
```

Expected result:

- the user exists
- home directory is `/home/veeamrepo`
- temporary membership in the `sudo` group is present

### Verify SSH

```bash
sshd -t
systemctl status ssh --no-pager
```

### Verify firewall

```bash
ufw status verbose
```

### Verify time synchronization

```bash
timedatectl
timedatectl show -p NTPSynchronized --value
timedatectl show -p LocalRTC --value
```

Recommended for Veeam:

- NTP synchronized
- RTC set to UTC

## Onboarding in Veeam

After `prepare`, use the following in Veeam:

- Linux server
- user `veeamrepo`
- home directory `/home/veeamrepo`
- single-use credentials

Do not remove `sudo` before this step.

## What to Check Before Lockdown

Run `post-attach-lockdown` only if:

- the repository has been added successfully in Veeam
- Veeam component deployment has completed successfully
- the repository is usable
- you have completed at least one backup test

## Final Phase: Lockdown

```bash
sudo bash ./veeam_hardened_repository_safe.sh \
  --phase post-attach-lockdown \
  --veeam-user veeamrepo \
  --veeam-group veeamrepo
```

## What to Check After `post-attach-lockdown`

### Verify that `veeamrepo` no longer has full sudo

```bash
id veeamrepo
groups veeamrepo
sudo -l -U veeamrepo
```

### Verify Veeam certificates

```bash
ls -ld /opt/veeam/transport/certs
```

### Verify SSH after lockdown

```bash
sshd -t
systemctl status ssh --no-pager
grep -R "DenyUsers" /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null
```

## Where to Find Script Logs

```bash
ls -l /var/log/veeam-hardened-repo
```

To find the latest run:

```bash
ls -dt /var/log/veeam-hardened-repo/run_* | head -n 1
```

To read it:

```bash
tail -n 200 /var/log/veeam-hardened-repo/run_*/main.log
```

If you want to be precise:

```bash
LATEST_LOG="$(ls -dt /var/log/veeam-hardened-repo/run_* | head -n 1)"
echo "$LATEST_LOG"
tail -n 200 "$LATEST_LOG/main.log"
```

## Useful Debug Commands

### Disks and mounts

```bash
lsblk -f
findmnt
df -h
```

### LVM status

```bash
pvs
vgs
lvs -a -o +devices
```

### SSH status

```bash
sshd -t
systemctl status ssh --no-pager
journalctl -u ssh -n 100 --no-pager
```

### Firewall status

```bash
ufw status numbered
ss -tulpn
```

### `veeamrepo` account status

```bash
id veeamrepo
getent passwd veeamrepo
passwd -S veeamrepo
sudo -l -U veeamrepo
```

### Time synchronization status

```bash
timedatectl
journalctl -u systemd-timesyncd -n 100 --no-pager
```

### Veeam components on Linux

```bash
ls -l /opt/veeam
systemctl list-units | grep -i veeam
ps -ef | grep -i veeam
```

## Common Errors

### `Invalid block device`

Check:

```bash
lsblk
```

### `The selected disk appears to be the system disk`

Check:

```bash
findmnt /
lsblk -f
```

### `Disk signatures are present on the target disk`

Check:

```bash
wipefs -n /dev/sdb
lsblk -f /dev/sdb
```

If you want to start from scratch and the disk is correct:

```bash
--force-wipe yes
```

### `The user veeamrepo exists but appears to have a locked or missing password`

Check:

```bash
passwd -S veeamrepo
```

If needed:

```bash
--reset-existing-veeam-password yes
```

### `Directory /opt/veeam/transport/certs was not found`

This usually means Veeam onboarding has not completed yet.

Check:

```bash
ls -l /opt/veeam
systemctl list-units | grep -i veeam
```

## Interactive Mode

If you want to be guided by the script:

```bash
sudo bash ./veeam_hardened_repository_safe.sh
```

If there is only one candidate disk, the script may suggest it automatically.

If there are multiple candidate disks, interactive mode will display them.

Non-interactive mode always requires an explicit `--disk`. Automatic disk
selection is intentionally disabled for unattended runs.

## Parameters the Operator Must Usually Decide

These are the most important values:

- `--disk`
- `--mount`
- `--repo-dir`
- `--ssh-net`
- `--veeam-net`
- `--force-wipe yes|no`

If you cannot confidently choose one of these values, stop and verify with the commands in this guide.

## Advanced and Hardening Tuning Parameters

These parameters have safe defaults and are usually left unchanged. They are
listed here so an operator can understand what each one affects before
overriding it. Run `--help` to see the full list with accepted values.

### Storage layout (`prepare`)

| Parameter | Default | Effect |
| --- | --- | --- |
| `--use-partition yes\|no` | `yes` | Create a GPT partition on the disk before using it as an LVM physical volume. Use `no` to consume the whole disk as a PV directly. |
| `--vg NAME` | `vg_veeam` | Name of the LVM volume group created on the repository disk. |
| `--lv NAME` | `lv_repo` | Name of the LVM logical volume that backs the repository filesystem. |
| `--lv-size SIZE\|100%FREE` | `100%FREE` | Size passed to `lvcreate` for the repository logical volume. |

### Network and firewall (`prepare`)

| Parameter | Default | Effect |
| --- | --- | --- |
| `--extra-ufw-rules "rule1;rule2"` | empty | Additional `ufw` rules applied as-is, separated by `;` (e.g. `"allow from 10.0.0.5 to any port 9392 proto tcp"`). |
| `--disable-ipv6 yes\|no` | `no` | Disable IPv6 at the kernel level via sysctl. |
| `--enable-ufw yes\|no` | `yes` | Enable and configure UFW. With `no`, firewall configuration is skipped entirely (not recommended). |

### SSH and authentication (`prepare`)

| Parameter | Default | Effect |
| --- | --- | --- |
| `--password-auth yes\|no` | `yes` | Allow SSH password authentication. With `no`, the Veeam user must already exist with a non-empty `authorized_keys` file. |
| `--reset-existing-veeam-password yes\|no` | `no` | If the `veeamrepo` user already exists with a locked/missing password, generate and set a new one. |
| `--show-generated-password yes\|no` | `no` | Print a newly generated password to the terminal. Leave disabled when output may be captured by orchestration or support logs; read the root-only credential file locally instead. |

### Audit and PAM hardening

| Parameter | Default | Effect |
| --- | --- | --- |
| `--enable-auditd yes\|no` | `yes` | Install and configure additive audit rules. Existing site rules are preserved. |
| `--enable-pam-hardening yes\|no` | `no` | Opt in to changes in `common-auth`, `common-password`, `faillock.conf`, and password-quality policy. Enable only after console recovery and a site-specific authentication test are available. |

### Updates and kernel hardening (`prepare`)

| Parameter | Default | Effect |
| --- | --- | --- |
| `--auto-security-updates yes\|no` | `yes` | Enable `unattended-upgrades` for security updates. |
| `--auto-reboot-updates yes\|no` | `no` | Allow `unattended-upgrades` to reboot automatically when required. |
| `--harden-userns yes\|no` | `yes` | Restrict unprivileged user namespaces via sysctl. |

### Boot and root account (`prepare`)

| Parameter | Default | Effect |
| --- | --- | --- |
| `--grub-password yes\|no` | `no` | Set a GRUB superuser password (PBKDF2 hash collected interactively or via `--non-interactive` prerequisites). Requires `update-grub`. |
| `--lock-root yes\|no` | `yes` | Lock the root account password (`passwd -l root`). |

### Post-attach lockdown (`--phase post-attach-lockdown`)

| Parameter | Default | Effect |
| --- | --- | --- |
| `--disable-ssh-for-user-after-attach yes\|no` | `yes` | Add a `DenyUsers` rule for `--veeam-user` in `sshd_config.d`, blocking interactive SSH for that account after onboarding. |
| `--disable-sshd-after-attach yes\|no` | `no` | Disable and stop the SSH service entirely. Only use this if you have another access path to the server (e.g. console access, IPMI). |

If you are unsure about any of these, keep the defaults: they reflect the
safer, recommended baseline for a Veeam Hardened Repository.

Automatic PAM changes are intentionally disabled by default because PAM
stacks can include organization-specific modules. This does not prevent Veeam
repository hardening; apply the organization's approved PAM policy separately,
or enable the option first on a staging clone.

## Practical Rule for Multiple Networks

If you need multiple allowed networks:

- use a single `--ssh-net`
- use a single `--veeam-net`
- separate networks with commas

Correct:

```bash
--ssh-net 192.168.10.0/24,192.168.20.0/24
--veeam-net 10.10.50.0/24,10.10.60.0/24
```

Incorrect:

```bash
--ssh-net 192.168.10.0/24 --ssh-net 192.168.20.0/24
--veeam-net 10.10.50.0/24 --veeam-net 10.10.60.0/24
```

In that case only the last value is used.

## Minimum Command Set to Keep Handy

```bash
lsblk -f
findmnt
pvs
vgs
lvs -a -o +devices
id veeamrepo
ufw status verbose
sshd -t
timedatectl
```

## Quick Summary

Before starting:

```bash
lsblk -f
wipefs -n /dev/sdb
```

Validation:

```bash
sudo bash ./veeam_hardened_repository_safe.sh --dry-run ...
sudo bash ./veeam_hardened_repository_safe.sh --precheck-only ...
```

Execution:

```bash
sudo bash ./veeam_hardened_repository_safe.sh --phase prepare ...
```

After Veeam onboarding:

```bash
sudo bash ./veeam_hardened_repository_safe.sh --phase post-attach-lockdown --veeam-user veeamrepo --veeam-group veeamrepo
```
