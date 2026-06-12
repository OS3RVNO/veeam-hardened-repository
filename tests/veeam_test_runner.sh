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

RESULTS=()
CREATED_LOOPS=()
CREATED_USERS=()
SCSI_DEBUG_LOADED=no

# Make unexpected aborts diagnosable and avoid leaking loop devices: dump the
# captured per-step output on failure and always detach the loops we created.
# Stderr is saved first so the dump is visible even when the abort happens
# inside a step whose output is redirected to a capture file.
exec {ORIG_STDERR}>&2
# The saved-stderr fd is intentionally inherited by child processes.
export LVM_SUPPRESS_FD_WARNINGS=1
on_runner_exit() {
    local rc=$? loop
    if (( rc != 0 )); then
        echo "Runner aborted with exit code ${rc}. Captured step output follows:" >&"$ORIG_STDERR"
        { cat /tmp/veeam_test*.out /tmp/veeam_test*.err 2>/dev/null || true; } >&"$ORIG_STDERR"
    fi
    for loop in "${CREATED_LOOPS[@]}"; do
        losetup -d "$loop" >/dev/null 2>&1 || true
    done
    for user in "${CREATED_USERS[@]}"; do
        userdel -r "$user" >/dev/null 2>&1 || true
    done
    if [[ "${SCSI_DEBUG_LOADED:-no}" == "yes" ]]; then
        modprobe -r scsi_debug >/dev/null 2>&1 || true
    fi
}
trap on_runner_exit EXIT

# Whole-disk device for tests that must pass --disk validation (loop devices
# are rejected by design). Provide one via VEEAM_TEST_DISK, or scsi_debug is
# loaded to create a 512MB RAM-backed disk.
TEST_DISK="${VEEAM_TEST_DISK:-}"
if [[ -z "$TEST_DISK" ]] && modprobe scsi_debug dev_size_mb=512 2>/dev/null; then
    SCSI_DEBUG_LOADED=yes
    udevadm settle 2>/dev/null || sleep 1
    TEST_DISK="$(lsblk -dn -o NAME,MODEL | awk '/scsi_debug/ {print "/dev/" $1; exit}')"
fi

# In containers /dev is a tmpfs without udev, so partition nodes created by
# the kernel never appear. Create the node from sysfs when it is missing.
ensure_block_node() {
    local node="$1"
    local maj min
    [[ -b "$node" ]] && return 0
    [[ -r "/sys/class/block/$(basename "$node")/dev" ]] || return 1
    IFS=: read -r maj min < "/sys/class/block/$(basename "$node")/dev"
    mknod "$node" b "$maj" "$min"
}

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
CREATED_LOOPS+=("$loop1")
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
ensure_block_node "$PARTITION_NAME"
pvcreate -ff -y "$PARTITION_NAME" >/dev/null
pvs "$PARTITION_NAME" >/dev/null
vgcreate "$VG_NAME" "$PARTITION_NAME" >/dev/null
fstab_bak1=/tmp/fstab.veeamtest1.bak
cp -a /etc/fstab "$fstab_bak1"
create_lvm >/tmp/veeam_test1_create_lvm.out 2>/tmp/veeam_test1_create_lvm.err
create_xfs >/tmp/veeam_test1_create_xfs.out 2>/tmp/veeam_test1_create_xfs.err
uuid1=$(blkid -s UUID -o value "/dev/${VG_NAME}/${LV_NAME}")
printf 'UUID=%s %s xfs %s 0 0\n' "$uuid1" "$REPO_DIR" "$FSTAB_OPTS" >> /etc/fstab
mount_repo >/tmp/veeam_test1_mount.out 2>/tmp/veeam_test1_mount.err
if mountpoint_in_use "$REPO_DIR" && ! mountpoint_in_use "$MOUNT_POINT"; then
  RESULTS+=(TEST1_OK)
else
  RESULTS+=(TEST1_FAIL)
  cat /tmp/veeam_test1_create_lvm.out /tmp/veeam_test1_create_lvm.err \
      /tmp/veeam_test1_create_xfs.out /tmp/veeam_test1_create_xfs.err \
      /tmp/veeam_test1_mount.out /tmp/veeam_test1_mount.err >&2 || true
fi
echo "${RESULTS[-1]}"

# Test 2: storage functions must be idempotent on already-prepared storage.
create_lvm >/tmp/veeam_test2_create_lvm.out 2>/tmp/veeam_test2_create_lvm.err
create_xfs >/tmp/veeam_test2_create_xfs.out 2>/tmp/veeam_test2_create_xfs.err
mount_repo >/tmp/veeam_test2_mount.out 2>/tmp/veeam_test2_mount.err
if mountpoint_in_use "$REPO_DIR" && grep -q "already" /tmp/veeam_test2_create_lvm.out /tmp/veeam_test2_create_lvm.err && grep -q "already" /tmp/veeam_test2_create_xfs.out /tmp/veeam_test2_create_xfs.err; then
  RESULTS+=(TEST2_OK)
else
  RESULTS+=(TEST2_FAIL)
  cat /tmp/veeam_test2_create_lvm.out /tmp/veeam_test2_create_lvm.err \
      /tmp/veeam_test2_create_xfs.out /tmp/veeam_test2_create_xfs.err \
      /tmp/veeam_test2_mount.out /tmp/veeam_test2_mount.err >&2 || true
fi
echo "${RESULTS[-1]}"
cp -a "$fstab_bak1" /etc/fstab
cleanup_loop "$VG_NAME" "$REPO_DIR" "$loop1"
rm -f "$fstab_bak1" "$img1"

# Test 3: a loop device must be rejected as --disk (only whole disks are
# supported), and even with a valid disk an unrelated filesystem on the
# expected partition must fail the precheck without force-wipe.
img2=/tmp/veeam_test2.img
truncate -s 256M "$img2"
loop2=$(losetup -f --show "$img2")
CREATED_LOOPS+=("$loop2")
parted -s "$loop2" mklabel gpt
parted -s -a optimal "$loop2" mkpart primary 1MiB 100%
partprobe "$loop2"
udevadm settle
part2="${loop2}p1"
ensure_block_node "$part2"
mkfs.ext4 -F "$part2" >/dev/null 2>&1
set +e
bash "$SCRIPT" --phase prepare --non-interactive --precheck-only --disk "$loop2" --mount /mnt/veeamtest2 --repo-dir /mnt/veeamtest2/backup --veeam-user veeamrepo --veeam-group veeamrepo --ssh-net 192.168.10.0/24 --veeam-net 192.168.10.0/24 >/tmp/veeam_test3.out 2>/tmp/veeam_test3.err
rc3=$?
set -e
if [[ $rc3 -ne 0 ]]; then
  RESULTS+=(TEST3_OK)
else
  RESULTS+=(TEST3_FAIL)
  cat /tmp/veeam_test3.out /tmp/veeam_test3.err >&2 || true
fi
echo "${RESULTS[-1]}"
losetup -d "$loop2" >/dev/null 2>&1 || true
rm -f "$img2"

# Test 4: helper must not accept a repo LV when it is not on the selected target disk.
find_repo_lv_path() { printf '%s\n' '/dev/vg_fake/lv_repo'; }
vg_is_fully_on_target_disk() { return 1; }
if find_target_repo_lv_path >/dev/null 2>&1; then
  RESULTS+=(TEST4_FAIL)
else
  RESULTS+=(TEST4_OK)
fi
echo "${RESULTS[-1]}"

# Test 5: post-attach-lockdown dry-run must complete without modifying the system.
# Keep a separate sudo-capable account present so the lockout safety precheck
# remains active without making this container-only test fail.
userdel -r veeamrepotest >/dev/null 2>&1 || true
userdel -r veeamadmintest >/dev/null 2>&1 || true
useradd -m -U veeamrepotest >/dev/null 2>&1
CREATED_USERS+=(veeamrepotest)
useradd -m -U veeamadmintest >/dev/null 2>&1
CREATED_USERS+=(veeamadmintest)
usermod -aG sudo veeamadmintest >/dev/null 2>&1
printf '%s:%s\n' veeamadmintest 'Veeam-Test-Admin-Password-1!' | chpasswd
set +e
bash "$SCRIPT" --phase post-attach-lockdown --non-interactive --dry-run --veeam-user veeamrepotest --veeam-group veeamrepotest >/tmp/veeam_test5.out 2>/tmp/veeam_test5.err
rc5=$?
set -e
if [[ $rc5 -eq 0 ]]; then
  RESULTS+=(TEST5_OK)
else
  RESULTS+=(TEST5_FAIL)
  cat /tmp/veeam_test5.out /tmp/veeam_test5.err >&2 || true
fi
echo "${RESULTS[-1]}"
userdel -r veeamrepotest >/dev/null 2>&1 || true
userdel -r veeamadmintest >/dev/null 2>&1 || true

# Test 6: full prepare dry-run on a blank whole disk must succeed and leave
# the system untouched. Needs a real disk device; skipped when none exists.
if [[ -n "$TEST_DISK" && -b "$TEST_DISK" ]]; then
  set +e
  bash "$SCRIPT" --phase prepare --non-interactive --dry-run --disk "$TEST_DISK" --mount /mnt/veeamtest6 --repo-dir /mnt/veeamtest6/backup --veeam-user veeamrepo6 --veeam-group veeamrepo6 --ssh-net 192.168.10.0/24 --veeam-net 192.168.10.0/24 >/tmp/veeam_test6.out 2>/tmp/veeam_test6.err
  rc6=$?
  set -e
  if [[ $rc6 -eq 0 ]] && [[ "$(lsblk -n -o NAME "$TEST_DISK" | wc -l)" -eq 1 ]] && [[ ! -e /mnt/veeamtest6 ]] && ! id veeamrepo6 >/dev/null 2>&1; then
    RESULTS+=(TEST6_OK)
  else
    RESULTS+=(TEST6_FAIL)
    cat /tmp/veeam_test6.out /tmp/veeam_test6.err >&2 || true
  fi
  echo "${RESULTS[-1]}"
else
  echo "TEST6_SKIP (no whole-disk test device available; set VEEAM_TEST_DISK)"
fi
if [[ "$SCSI_DEBUG_LOADED" == "yes" ]]; then
  modprobe -r scsi_debug 2>/dev/null || true
fi

rm -f "$NOMAIN"

if (( ${#RESULTS[@]} < 5 )); then
  echo "The runner terminated early: only ${#RESULTS[@]} of at least 5 expected test results were produced." >&2
  exit 1
fi
for result in "${RESULTS[@]}"; do
  case "$result" in
    *_FAIL) echo "One or more tests failed." >&2; exit 1 ;;
  esac
done
