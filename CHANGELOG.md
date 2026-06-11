# Changelog

## 2026.06.11

- validate `--vg` and `--lv` against LVM naming rules before storage
  operations start, and reject identical VG/LV names
- removed a dead `X11UseLocalhost yes` line from the SSH hardening
  drop-in (meaningless when `X11Forwarding no` is set)
- made the `sshd_config` `Include /etc/ssh/sshd_config.d/*.conf` detection
  tolerant of trailing comments/whitespace, avoiding a duplicate `Include`
  line on rerun against a customized `sshd_config`

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
