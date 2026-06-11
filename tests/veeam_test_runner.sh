#!/usr/bin/env bash
# Integration tests for veeam_hardened_repository_safe.sh.
# Requires root and Linux tools: losetup, parted, lvm2, xfsprogs, util-linux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT="${SCRIPT_DIR}/../veeam_hardened_repository_safe.sh"
NOMAIN=/tmp/veeam_no_main.sh
head -n -1 "$SCRIPT" > "$NOMAIN"
# shellcheck source=/dev/null
source "$NOMAIN"
trap - ERR

cleanup_loop() {
    local vg_name="$1"
    local mount_target="$2"
    local loop_dev="$3"
    set +e
    if mountpoint -q "$mount_target" 2>/dev/null; then umount "$mount_target"; fi
    if vgs "$vg_name" >/dev/null 2>&1; then vgchange -an "$vg_name" >/dev/null 2>&1 || true; vgremove -ff "$vg_name" >/dev/null 2>&1 || true; fi
    losetup -d "$loop_dev" >/dev/null 2>&1 || true
    set -e
}

# Test 1: repair partial PV+VG state and recover mount on REPO_DIR.
img1=/tmp/veeam_test1.img
truncate -s 512M "$img1"
loop1=$(losetup -f --show "$img1")
BACKUP_DISK="$loop1"
# shellcheck disable=SC2034 # consumed as globals by functions sourced from NOMAIN
USE_PARTITION=yes
VG_NAME=vg_vtest1
LV_NAME=lv_repo
# shellcheck disable=SC2034
LV_SIZE=100%FREE
MOUNT_POINT=/mnt/veeamtest1
REPO_DIR=/mnt/veeamtest1/backup
FSTAB_OPTS=defaults,noatime
# shellcheck disable=SC2034
FORCE_WIPE=no
# shellcheck disable=SC2034
DRY_RUN=no
# shellcheck disable=SC2034
INTERACTIVE=no
mkdir -p "$MOUNT_POINT" "$REPO_DIR"
init_logging
parted -s "$BACKUP_DISK" mklabel gpt
parted -s -a optimal "$BACKUP_DISK" mkpart primary 1MiB 100%
parted -s "$BACKUP_DISK" set 1 lvm on
partprobe "$BACKUP_DISK"
udevadm settle
detect_partition_name
pvcreate -ff -y "$PARTITION_NAME" >/dev/null
vgcreate "$VG_NAME" "$PARTITION_NAME" >/dev/null
fstab_bak1=/tmp/fstab.veeamtest1.bak
cp -a /etc/fstab "$fstab_bak1"
create_lvm >/tmp/veeam_test1_create_lvm.out 2>/tmp/veeam_test1_create_lvm.err
create_xfs >/tmp/veeam_test1_create_xfs.out 2>/tmp/veeam_test1_create_xfs.err
uuid1=$(blkid -s UUID -o value "/dev/${VG_NAME}/${LV_NAME}")
printf 'UUID=%s %s xfs %s 0 0\n' "$uuid1" "$REPO_DIR" "$FSTAB_OPTS" >> /etc/fstab
mount_repo >/tmp/veeam_test1_mount.out 2>/tmp/veeam_test1_mount.err
if mountpoint_in_use "$REPO_DIR" && ! mountpoint_in_use "$MOUNT_POINT"; then
  echo TEST1_OK
else
  echo TEST1_FAIL
fi
cp -a "$fstab_bak1" /etc/fstab
cleanup_loop "$VG_NAME" "$REPO_DIR" "$loop1"
rm -f "$fstab_bak1" "$img1"

# Test 2: unrelated filesystem on expected partition must fail without force-wipe.
img2=/tmp/veeam_test2.img
truncate -s 256M "$img2"
loop2=$(losetup -f --show "$img2")
parted -s "$loop2" mklabel gpt
parted -s -a optimal "$loop2" mkpart primary 1MiB 100%
partprobe "$loop2"
udevadm settle
part2="${loop2}p1"
mkfs.ext4 -F "$part2" >/dev/null 2>&1
set +e
"$SCRIPT" --phase prepare --non-interactive --precheck-only --disk "$loop2" --mount /mnt/veeamtest2 --repo-dir /mnt/veeamtest2/backup --veeam-user veeamrepo --veeam-group veeamrepo --ssh-net 192.168.10.0/24 --veeam-net 192.168.10.0/24 >/tmp/veeam_test2.out 2>/tmp/veeam_test2.err
rc2=$?
set -e
if [[ $rc2 -ne 0 ]]; then
  echo TEST2_OK
else
  echo TEST2_FAIL
fi
losetup -d "$loop2" >/dev/null 2>&1 || true
rm -f "$img2"

# Test 3: helper must not accept a repo LV when it is not on the selected target disk.
find_repo_lv_path() { printf '%s\n' '/dev/vg_fake/lv_repo'; }
vg_is_fully_on_target_disk() { return 1; }
if find_target_repo_lv_path >/dev/null 2>&1; then
  echo TEST3_FAIL
else
  echo TEST3_OK
fi

rm -f "$NOMAIN"
