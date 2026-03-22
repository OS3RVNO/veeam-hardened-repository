---
name: Bug report
about: Report a problem with the script or documentation
title: "[Bug] "
labels: bug
assignees: ""
---

## Summary

Describe the issue clearly.

## Command Used

```bash
# Paste the command here
```

## Phase

- [ ] prepare
- [ ] post-attach-lockdown
- [ ] dry-run
- [ ] precheck-only

## Environment

- Ubuntu version:
- Veeam version:
- Interactive or non-interactive:

## Relevant Output

Paste only the relevant log or command output.

## Validation Commands

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
