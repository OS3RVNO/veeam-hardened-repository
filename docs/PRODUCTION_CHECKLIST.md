# Production Readiness Checklist

Use this checklist for the exact server and storage that will become the
Veeam Hardened Repository.

## Host and Recovery Access

- [ ] Ubuntu 22.04 LTS or 24.04 LTS is fully patched.
- [ ] The server is dedicated to the repository role.
- [ ] Veeam Agent for Linux is not installed.
- [ ] Out-of-band or local console access has been tested.
- [ ] A separate local sudo administrator has a working password or SSH key.
- [ ] NTP is synchronized and the hardware clock uses UTC.

## Storage and Network

- [ ] The repository disk model, size, serial, and device path were recorded.
- [ ] Non-interactive runs use an explicit `--disk`; `auto` is not used.
- [ ] The operating-system disks were identified independently with `findmnt`
      and `lsblk`.
- [ ] Existing signatures were reviewed with `wipefs -n`.
- [ ] `--force-wipe yes` is used only for a disk approved for destruction.
- [ ] SSH and Veeam CIDRs include only required infrastructure networks.
- [ ] Existing UFW rules were reviewed for broad legacy allow rules.

## Script Validation

- [ ] Run `--dry-run` using the intended production arguments.
- [ ] Run `--precheck-only` using the intended production arguments.
- [ ] Review the generated log under `/var/log/veeam-hardened-repo`.
- [ ] Leave `--show-generated-password no` when output is captured.
- [ ] Leave `--enable-pam-hardening no` unless the PAM changes were tested on
      an equivalent staging clone with console recovery.

## Veeam Acceptance Test

- [ ] Complete `prepare`.
- [ ] Add the repository with single-use credentials.
- [ ] Run a backup job with immutability enabled.
- [ ] Perform a test restore from the repository.
- [ ] Confirm the repository is healthy after a rescan.
- [ ] Complete `post-attach-lockdown`.
- [ ] Verify the Veeam user is no longer in `sudo`.
- [ ] Verify the Veeam user cannot log in through SSH.
- [ ] Run another backup and restore test after lockdown.
- [ ] Remove the root-only generated credential file after acceptance.

Do not promote the host to production if any required check is incomplete.
