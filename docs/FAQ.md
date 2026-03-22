# FAQ

## Why is the workflow split into `prepare` and `post-attach-lockdown`?

Because Veeam onboarding is easier and more reliable when the repository user still has temporary elevation during the first attach. The script keeps that path safer, then reduces access afterwards.

## Why not remove `veeamrepo` from `sudo` immediately?

Removing elevation too early is one of the most common reasons the first Veeam connection becomes unnecessarily painful. This project intentionally avoids that trap.

## Can I use multiple networks for `--ssh-net` and `--veeam-net`?

Yes. Use a single argument and separate the networks with commas.

Example:

```bash
--ssh-net 192.168.10.0/24,192.168.20.0/24
--veeam-net 10.10.50.0/24,10.10.60.0/24
```

## Does the script support Ubuntu 22.04 and 24.04?

Yes. The script is designed for Ubuntu `22.04 LTS` and `24.04 LTS`.

## Does the script format the repository disk?

It can, depending on the chosen options. Always validate the target disk first and treat `--force-wipe yes` as a destructive action.

## Can I run it in a validation mode first?

Yes. Use:

```bash
--dry-run
```

or:

```bash
--precheck-only
```

## Is the script intended only for advanced Linux administrators?

No. It is specifically designed to help sysadmins who may know Veeam well but want a more guided Linux setup process.

## Does the project include practical debug commands?

Yes. The operational guide and support file include commands for:

- disks and mounts
- LVM
- SSH
- UFW
- `veeamrepo`
- time synchronization
- Veeam component checks
