# Support

## Before Opening an Issue

Please collect the following first:

- the command you executed
- whether you used `--dry-run`, `--precheck-only`, `prepare`, or `post-attach-lockdown`
- the relevant output from `/var/log/veeam-hardened-repo`
- the output of the basic validation commands below

## Useful Validation Commands

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

## Scope

This repository is intended for:

- Ubuntu `22.04 LTS`
- Ubuntu `24.04 LTS`
- Veeam Hardened Repository preparation with the provided script

## Not in Scope

- generic Linux administration unrelated to the script
- unsupported distributions
- destructive storage changes performed outside the documented workflow
