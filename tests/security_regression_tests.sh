#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317 # globals and mocks are consumed by sourced functions
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT="${SCRIPT_DIR}/../veeam_hardened_repository_safe.sh"
NOMAIN="$(mktemp)"
trap 'rm -f "$NOMAIN"' EXIT

head -n -1 "$SCRIPT" > "$NOMAIN"
# shellcheck source=/dev/null
source "$NOMAIN"
trap - ERR

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

validate_mount_path "/veeamrepo" || fail "valid mount path was rejected"
validate_mount_path "/veeamrepo/backup" || fail "valid repository path was rejected"

if ! (
    MOUNT_POINT="/veeamrepo"
    REPO_DIR="/veeamrepo/backup"
    validate_repository_paths
); then
    fail "complete repository path validation returned failure for valid paths"
fi

if ! (
    DRY_RUN="yes"
    ensure_fstab_entry "/dev/vg_missing/lv_missing" "/veeamrepo"
) >/dev/null 2>&1; then
    fail "dry-run fstab handling failed when the simulated LV did not exist"
fi

for unsafe_path in \
    "/veeamrepo/../etc" \
    "/veeamrepo/./backup" \
    "/veeamrepo//backup" \
    "veeamrepo/backup"; do
    if validate_mount_path "$unsafe_path"; then
        fail "unsafe path was accepted: ${unsafe_path}"
    fi
done

generated_password="$(generate_random_password)"
[[ ${#generated_password} -eq 24 ]] || fail "generated password length is not 24"
[[ "$generated_password" =~ [A-Z] ]] || fail "generated password lacks uppercase characters"
[[ "$generated_password" =~ [a-z] ]] || fail "generated password lacks lowercase characters"
[[ "$generated_password" =~ [0-9] ]] || fail "generated password lacks digits"
[[ "$generated_password" =~ [!@#%_=+.-] ]] || fail "generated password lacks special characters"

system_disks="$(
    (
        findmnt() {
            printf '%s\n' "/dev/mapper/ubuntu--vg-root"
        }
        canonicalize_block_device() {
            printf '%s\n' "$1"
        }
        lsblk() {
            [[ " $* " == *" -s "* ]] || return 1
            printf '%s\n' \
                "/dev/mapper/ubuntu--vg-root lvm" \
                "/dev/sda3 part" \
                "/dev/sda disk"
        }
        get_system_disks
    )
)"
[[ "$system_disks" == "/dev/sda" ]] || fail "root LVM ancestry did not resolve to /dev/sda"

if (
    BACKUP_DISK="auto"
    INTERACTIVE="no"
    maybe_autodetect_backup_disk
) >/dev/null 2>&1; then
    fail "non-interactive mode accepted automatic disk selection"
fi

if (
    ALLOW_PASSWORD_AUTH="no"
    VEEAM_USER="veeamrepo"
    id() {
        return 1
    }
    validate_prepare_access_inputs
) >/dev/null 2>&1; then
    fail "password-disabled onboarding accepted a missing Veeam SSH user"
fi

if ! (
    ALLOW_PASSWORD_AUTH="no"
    VEEAM_USER="veeamrepo"
    id() {
        return 0
    }
    user_has_authorized_keys() {
        return 0
    }
    validate_prepare_access_inputs
); then
    fail "password-disabled onboarding rejected an existing keyed Veeam user"
fi

if (
    VEEAM_USER="veeamrepo"
    getent() {
        case "$1:$2" in
            group:sudo) printf '%s\n' "sudo:x:27:veeamrepo,adminuser" ;;
            passwd:adminuser) printf '%s\n' "adminuser:x:1001:1001::/home/adminuser:/bin/bash" ;;
        esac
    }
    passwd() {
        printf '%s\n' "adminuser L 2026-01-01 0 99999 7 -1"
    }
    user_has_authorized_keys() {
        return 1
    }
    alternate_admin_account_exists
); then
    fail "locked alternate admin without keys was accepted"
fi

if ! (
    VEEAM_USER="veeamrepo"
    getent() {
        case "$1:$2" in
            group:sudo) printf '%s\n' "sudo:x:27:veeamrepo,adminuser" ;;
            passwd:adminuser) printf '%s\n' "adminuser:x:1001:1001::/home/adminuser:/bin/bash" ;;
        esac
    }
    passwd() {
        printf '%s\n' "adminuser P 2026-01-01 0 99999 7 -1"
    }
    user_has_authorized_keys() {
        return 1
    }
    alternate_admin_account_exists
); then
    fail "usable alternate admin was rejected"
fi

if (
    BACKUP_DISK="/dev/sdb"
    get_system_disks() {
        return 1
    }
    check_disk_is_not_system_disk
) >/dev/null 2>&1; then
    fail "storage preparation continued when the system disk was unknown"
fi

VEEAM_USER="veeamrepo"
VEEAM_PASSWORD="RegressionSecret-DoNotLog"
TIMESTAMP="test"
SHOW_GENERATED_PASSWORD="no"
credentials_output="$(show_credentials_if_any 2>&1)"
[[ "$credentials_output" != *"$VEEAM_PASSWORD"* ]] || fail "generated password leaked to default output"
[[ "$credentials_output" == *"/root/.veeam_repo_credentials_test"* ]] || fail "credential file location was not reported"

SHOW_GENERATED_PASSWORD="yes"
credentials_output="$(show_credentials_if_any 2>&1)"
[[ "$credentials_output" == *"$VEEAM_PASSWORD"* ]] || fail "explicit password display option did not work"

if grep -Eq '^[[:space:]]*-D([[:space:]]|$)' "$SCRIPT"; then
    fail "audit rules still contain a global delete directive"
fi

PRECHECK_ONLY="yes"
INTERACTIVE="no"
timezone_marker="$(
    (
        validate_prepare_inputs() { :; }
        banner() { :; }
        show_prepare_summary() { :; }
        confirm_destruction_if_needed() { :; }
        final_confirm() { :; }
        prechecks_prepare() { :; }
        ensure_timezone_europe_rome() { printf '%s\n' "TIMEZONE_CHANGED"; }
        prepare_flow
    )
)"
[[ "$timezone_marker" != *"TIMEZONE_CHANGED"* ]] || fail "precheck-only attempted to change timezone"

printf '%s\n' "Security regression tests passed."
