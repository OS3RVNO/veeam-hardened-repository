# Changelog

## 2026.06.12

- rename the terminal and repository presentation to `hard-repo`
- refresh the GitHub README banner, status badges, safety summary, and
  production gate
- make the full Docker flow clean up containers, test LVM state, and
  `scsi_debug` disks by default
- make successful repository path validation return zero explicitly under
  `set -e`
- keep `--dry-run` from aborting when the simulated logical volume has no
  UUID yet
- make the integration runner unload `scsi_debug` after unexpected exits
- reject repository paths containing `.` or `..` components, repeated
  separators, or paths outside the selected mount point
- resolve the root filesystem through its full `lsblk` parent chain so LVM
  and device-mapper roots are mapped back to their physical disks
- refuse `--force-wipe yes` when the running system disk cannot be determined
- stop when a non-mounted repository path would hide existing data
- make destructive cleanup fail closed when PV, signature, GPT, or partition
  table cleanup fails
- keep `--precheck-only` from changing the system timezone
- stop printing generated credentials by default; use
  `--show-generated-password yes` only for an attended run
- make automatic PAM file changes opt-in with
  `--enable-pam-hardening yes`
- remove the audit rules global `-D` directive so existing site audit rules
  are preserved
- add non-destructive security regression tests to CI

## 2026.06.11

- validate `--vg` and `--lv` against LVM naming rules before storage
  operations start, and reject identical VG/LV names
- removed a dead `X11UseLocalhost yes` line from the SSH hardening
  drop-in (meaningless when `X11Forwarding no` is set)
- made the `sshd_config` `Include /etc/ssh/sshd_config.d/*.conf` detection
  tolerant of trailing comments/whitespace, avoiding a duplicate `Include`
  line on rerun against a customized `sshd_config`
- `ensure_timezone_europe_rome` now honors `--dry-run` instead of always
  changing the system timezone, so a dry run no longer has side effects
- `enforce_sticky_bit_post_attach` now skips its filesystem scan under
  `--dry-run` instead of walking every local mount, which could take a
  very long time on hosts with large filesystems

## 2026.03.23

The script now uses date-based versioning (`SCRIPT_VERSION`), matching this
changelog entry.

- added an optional `whiptail`/`dialog` TUI for interactive prompts, with a
  plain-text fallback
- added storage recovery: detect and repair partial PV/VG/LV state and
  recover an existing repository mount instead of failing or re-wiping
- added stricter validation for the target disk and repository paths
  (whole-disk checks, symlink-component checks, fstab/source matching)
- added account policy, password quality, and time-sync configuration during
  `prepare`
- expanded `post-attach-lockdown`: PAM hardening, auditd rules, AIDE setup,
  sticky-bit enforcement, GRUB audit boot flag, SSH auth policy, and removal
  of `veeamrepo` sudo access
- added detection of an existing Veeam Agent for Linux installation and
  Europe/Rome timezone enforcement
- numerous internal refactors for safer fstab editing, PAM module ordering,
  and disk/VG/LV inspection helpers

## 1.0.0

- initial public release of the Veeam Hardened Repository bootstrap script
- English script interface and documentation
- safer two-phase workflow for first attach and post-attach lockdown
- improved GitHub presentation with support, security, FAQ, and issue templates
- visual assets for repository presentation
