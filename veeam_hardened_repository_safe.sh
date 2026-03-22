#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2026.03.21"

# --------------------[ Defaults ]--------------------
DEFAULT_PHASE="prepare"
DEFAULT_BACKUP_DISK="auto"
DEFAULT_USE_PARTITION="yes"
DEFAULT_VG_NAME="vg_veeam"
DEFAULT_LV_NAME="lv_repo"
DEFAULT_LV_SIZE="100%FREE"
DEFAULT_MOUNT_POINT="/veeamrepo"
DEFAULT_REPO_DIR="/veeamrepo/backup"
DEFAULT_FS_LABEL="VEEAMREPO"
DEFAULT_FSTAB_OPTS="defaults,noatime"
DEFAULT_VEEAM_USER="veeamrepo"
DEFAULT_VEEAM_GROUP="veeamrepo"
DEFAULT_SSH_ALLOWED_NETS=""
DEFAULT_VEEAM_ALLOWED_NETS=""
DEFAULT_EXTRA_UFW_RULES=""
DEFAULT_FORCE_WIPE="no"
DEFAULT_DISABLE_IPV6="no"
DEFAULT_ENABLE_UFW="yes"
DEFAULT_ALLOW_PASSWORD_AUTH="yes"
DEFAULT_ENABLE_AUTO_SECURITY_UPDATES="yes"
DEFAULT_AUTO_REBOOT_UPDATES="no"
DEFAULT_HARDEN_USERNS="yes"
DEFAULT_SET_GRUB_PASSWORD="no"
DEFAULT_LOCK_ROOT_PASSWORD="yes"
DEFAULT_DISABLE_SSH_FOR_USER_AFTER_ATTACH="yes"
DEFAULT_DISABLE_SSHD_AFTER_ATTACH="no"
DEFAULT_RESET_EXISTING_VEEAM_PASSWORD="no"

# --------------------[ Runtime flags ]--------------------
PHASE="$DEFAULT_PHASE"
INTERACTIVE="yes"
PRECHECK_ONLY="no"
DRY_RUN="no"
CURRENT_SECTION="BOOT"

# --------------------[ Runtime values ]--------------------
BACKUP_DISK="$DEFAULT_BACKUP_DISK"
USE_PARTITION="$DEFAULT_USE_PARTITION"
VG_NAME="$DEFAULT_VG_NAME"
LV_NAME="$DEFAULT_LV_NAME"
LV_SIZE="$DEFAULT_LV_SIZE"
MOUNT_POINT="$DEFAULT_MOUNT_POINT"
REPO_DIR="$DEFAULT_REPO_DIR"
FS_LABEL="$DEFAULT_FS_LABEL"
FSTAB_OPTS="$DEFAULT_FSTAB_OPTS"
VEEAM_USER="$DEFAULT_VEEAM_USER"
VEEAM_GROUP="$DEFAULT_VEEAM_GROUP"
SSH_ALLOWED_NETS="$DEFAULT_SSH_ALLOWED_NETS"
VEEAM_ALLOWED_NETS="$DEFAULT_VEEAM_ALLOWED_NETS"
EXTRA_UFW_RULES="$DEFAULT_EXTRA_UFW_RULES"
FORCE_WIPE="$DEFAULT_FORCE_WIPE"
DISABLE_IPV6="$DEFAULT_DISABLE_IPV6"
ENABLE_UFW="$DEFAULT_ENABLE_UFW"
ALLOW_PASSWORD_AUTH="$DEFAULT_ALLOW_PASSWORD_AUTH"
ENABLE_AUTO_SECURITY_UPDATES="$DEFAULT_ENABLE_AUTO_SECURITY_UPDATES"
AUTO_REBOOT_UPDATES="$DEFAULT_AUTO_REBOOT_UPDATES"
HARDEN_USERNS="$DEFAULT_HARDEN_USERNS"
SET_GRUB_PASSWORD="$DEFAULT_SET_GRUB_PASSWORD"
LOCK_ROOT_PASSWORD="$DEFAULT_LOCK_ROOT_PASSWORD"
DISABLE_SSH_FOR_USER_AFTER_ATTACH="$DEFAULT_DISABLE_SSH_FOR_USER_AFTER_ATTACH"
DISABLE_SSHD_AFTER_ATTACH="$DEFAULT_DISABLE_SSHD_AFTER_ATTACH"
RESET_EXISTING_VEEAM_PASSWORD="$DEFAULT_RESET_EXISTING_VEEAM_PASSWORD"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
LOG_BASE_DIR="/var/log/veeam-hardened-repo"
LOG_DIR="${LOG_BASE_DIR}/run_${TIMESTAMP}"
MAIN_LOG="${LOG_DIR}/main.log"
TIMESTAMP_FILE="/etc/veeam-hardened-repo/last_prepare.env"
GRUB_PBKDF2_HASH=""
PARTITION_NAME=""
OS_ID=""
OS_VERSION_ID=""
OS_PRETTY_NAME=""
VEEAM_PASSWORD=""
VEEAM_USER_WAS_CREATED="no"

# --------------------[ Colors ]--------------------
if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_BLUE="\033[34m"
    C_CYAN="\033[36m"
    C_WHITE="\033[37m"
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
    C_WHITE=""
fi

# --------------------[ UI ]--------------------
ui() { printf "%b\n" "$*" >&2; }
ui_inline() { printf "%b" "$*" >&2; }
line() { printf "%b\n" "${C_DIM}-----------------------------------------------------------------${C_RESET}" >&2; }

banner() {
    clear 2>/dev/null || true
    ui "${C_CYAN}${C_BOLD}"
    cat >&2 <<'EOF'
 __     __                                  _
 \ \   / /__  ___  __ _ _ __ ___           | |__   ___ _ __   ___
  \ \ / / _ \/ _ \/ _` | '_ ` _ \   _____  | '_ \ / _ \ '_ \ / _ \
   \ V /  __/  __/ (_| | | | | | | |_____| | | | |  __/ | | |  __/
    \_/ \___|\___|\__,_|_| |_| |_|         |_| |_|\___|_| |_|\___|

EOF
    ui "${C_RESET}${C_BOLD}Hardened Repository Safer Bootstrap${C_RESET}"
    ui "${C_DIM}Version: ${SCRIPT_VERSION} | Phase: ${PHASE} | Log: ${LOG_DIR}${C_RESET}"
    line
}

section() {
    CURRENT_SECTION="$1"
    ui ""
    ui "${C_BLUE}${C_BOLD}[${CURRENT_SECTION}] $2${C_RESET}"
    line
}

ok()   { ui "${C_GREEN}[OK]${C_RESET} $1"; }
warn() { ui "${C_YELLOW}[WARN]${C_RESET} $1"; }
info() { ui "${C_CYAN}[INFO]${C_RESET} $1"; }
err()  { ui "${C_RED}[ERR]${C_RESET} $1"; }

pause_enter() {
    [[ "$INTERACTIVE" == "yes" ]] || return 0
    read -r -p "$(printf '%b' "${C_DIM}Press ENTER to continue...${C_RESET}")"
}

# --------------------[ Logging ]--------------------
log() {
    local ts
    ts="$(date '+%F %T' 2>/dev/null || echo 'DATE-ERROR')"
    printf '[%s] [%s] %s\n' "$ts" "$CURRENT_SECTION" "$*" >> "$MAIN_LOG" 2>/dev/null || true
}

quote_cmd() {
    local quoted=()
    local item
    for item in "$@"; do
        quoted+=("$(printf '%q' "$item")")
    done
    printf '%s ' "${quoted[@]}"
}

run() {
    local desc="$1"
    shift
    local cmd_text
    cmd_text="$(quote_cmd "$@")"

    info "-> $desc"
    log "CMD: $cmd_text"

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN: $cmd_text"
        return 0
    fi

    if "$@" >>"$MAIN_LOG" 2>&1; then
        ok "$desc"
        return 0
    fi

    err "$desc"
    return 1
}

run_or_die() {
    local desc="$1"
    shift
    run "$desc" "$@" || die "Blocking error: ${desc}"
}

die() {
    err "$*"
    log "FATAL: $*"
    exit 1
}

on_error() {
    local line_no="$1"
    local exit_code="$2"
    err "Unexpected error at line ${line_no} (exit ${exit_code}). See ${MAIN_LOG}"
}
trap 'on_error "${LINENO}" "$?"' ERR

# --------------------[ Helpers ]--------------------
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script as root or with sudo."
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

normalize_ws() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

is_yes() { [[ "$1" =~ ^([yY]([eE][sS])?|[sS][iI])$ ]]; }
is_no()  { [[ "$1" =~ ^([nN]([oO])?)$ ]]; }

validate_yes_no() {
    is_yes "$1" || is_no "$1"
}

validate_linux_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_group_name() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_mount_path() {
    [[ "$1" =~ ^/[A-Za-z0-9._/-]*$ ]]
}

validate_lv_size() {
    [[ "$1" =~ ^[0-9]+([KkMmGgTtPpEe])$ ]] || [[ "$1" =~ ^[0-9]+%([A-Za-z]+)$ ]]
}

validate_ipv4_octet() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 0 && n <= 255 ))
}

validate_ipv4_cidr() {
    local cidr="$1"
    local ip prefix
    IFS='/' read -r ip prefix <<< "$cidr"
    [[ -n "${ip:-}" && -n "${prefix:-}" ]] || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( prefix >= 0 && prefix <= 32 )) || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    validate_ipv4_octet "$o1" &&
    validate_ipv4_octet "$o2" &&
    validate_ipv4_octet "$o3" &&
    validate_ipv4_octet "$o4"
}

validate_net_csv() {
    local csv="$1"
    local item
    IFS=',' read -r -a nets <<< "$csv"
    for item in "${nets[@]}"; do
        item="$(normalize_ws "$item")"
        [[ -n "$item" ]] || return 1
        validate_ipv4_cidr "$item" || return 1
    done
}

validate_extra_ufw_rules() {
    [[ "$1" != *$'\n'* ]]
}

validate_block_device() { [[ -b "$1" ]]; }

path_is_under_mountpoint() {
    local path="$1"
    local base="$2"
    [[ "$path" == "$base" || "$path" == "$base/"* ]]
}

path_mount_target() {
    findmnt -n -o TARGET --target "$1" 2>/dev/null || true
}

mountpoint_in_use() {
    findmnt -n --target "$1" >/dev/null 2>&1
}

dir_nonempty() {
    [[ -d "$1" ]] && find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .
}

backup_file() {
    local file="$1"
    [[ -e "$file" ]] || return 0
    [[ "$DRY_RUN" == "yes" ]] && return 0
    cp -a "$file" "${file}.bak_${TIMESTAMP}"
}

write_file() {
    local target="$1"
    local mode="$2"
    local owner="${3:-root}"
    local group="${4:-root}"
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp"

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN write ${target}"
        rm -f "$tmp"
        return 0
    fi

    if [[ -e "$target" ]]; then
        backup_file "$target"
    fi

    install -o "$owner" -g "$group" -m "$mode" "$tmp" "$target"
    rm -f "$tmp"
}

set_kv_in_file() {
    local key="$1"
    local value="$2"
    local file="$3"
    local tmp

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN set ${key}=${value} in ${file}"
        return 0
    fi

    tmp="$(mktemp)"
    touch "$file"
    if grep -qE "^[#[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -E "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|g" "$file" > "$tmp"
    else
        cat "$file" > "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    backup_file "$file"
    install -o root -g root -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

append_line_if_missing() {
    local file="$1"
    local line_text="$2"

    if grep -Fxq "$line_text" "$file" 2>/dev/null; then
        return 0
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN append line to ${file}: ${line_text}"
        return 0
    fi

    backup_file "$file"
    printf '%s\n' "$line_text" >> "$file"
}

generate_random_password() {
    tr -dc 'A-Za-z0-9!@#%_=+.-' < /dev/urandom | head -c 24
}

ensure_safe_workdir() {
    cd /root 2>/dev/null || cd / || true
}

init_logging() {
    mkdir -p "$LOG_DIR"
    chmod 700 "$LOG_BASE_DIR" "$LOG_DIR" 2>/dev/null || true
}

load_os_release() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION_ID="${VERSION_ID:-}"
        OS_PRETTY_NAME="${PRETTY_NAME:-unknown}"
    fi
}

ubuntu_supported() {
    [[ "$OS_ID" == "ubuntu" && ( "$OS_VERSION_ID" == "22.04" || "$OS_VERSION_ID" == "24.04" ) ]]
}

detect_partition_name() {
    if [[ "$BACKUP_DISK" =~ nvme[0-9]+n[0-9]+$ ]]; then
        PARTITION_NAME="${BACKUP_DISK}p1"
    else
        PARTITION_NAME="${BACKUP_DISK}1"
    fi
}

get_system_disk() {
    local root_source pkname
    root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ -n "$root_source" ]] || return 1
    pkname="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
    [[ -n "$pkname" ]] || return 1
    printf '/dev/%s\n' "$pkname"
}

list_candidate_backup_disks() {
    local system_disk name type size model
    system_disk="$(get_system_disk || true)"

    while read -r name type size model; do
        [[ "$type" == "disk" ]] || continue
        [[ -n "$name" ]] || continue
        [[ "/dev/${name}" == "$system_disk" ]] && continue
        printf '/dev/%s|%s|%s\n' "$name" "$size" "${model:-unknown}"
    done < <(lsblk -dn -e 2,11 -o NAME,TYPE,SIZE,MODEL 2>/dev/null)
}

show_candidate_backup_disks() {
    local disk size model idx=1
    ui "${C_BOLD}Candidate repository disks:${C_RESET}"
    while IFS='|' read -r disk size model; do
        ui "  ${idx}) ${disk} - ${size} - ${model}"
        ((idx++))
    done < <(list_candidate_backup_disks)
}

maybe_autodetect_backup_disk() {
    local candidate_count=0
    local last_candidate=""
    local disk size model

    if [[ "$BACKUP_DISK" != "auto" && -b "$BACKUP_DISK" ]]; then
        return 0
    fi

    while IFS='|' read -r disk size model; do
        [[ -n "$disk" ]] || continue
        last_candidate="$disk"
        ((candidate_count++))
    done < <(list_candidate_backup_disks)

    if (( candidate_count == 1 )); then
        BACKUP_DISK="$last_candidate"
        info "Repository disk auto-detected: ${BACKUP_DISK}"
        return 0
    fi

    if (( candidate_count == 0 )); then
        die "No candidate repository disk could be auto-detected. Specify --disk /dev/sdX."
    fi

    if [[ "$INTERACTIVE" == "yes" ]]; then
        pick_disk_interactive
        return 0
    fi

    show_candidate_backup_disks
    die "Multiple candidate disks were found. In non-interactive mode you must explicitly specify --disk /dev/sdX."
}

autofill_repo_dir_from_mount() {
    if [[ -z "$REPO_DIR" || "$REPO_DIR" == "/backup" ]]; then
        REPO_DIR="${MOUNT_POINT%/}/backup"
        return 0
    fi

    if [[ "$REPO_DIR" == "$DEFAULT_REPO_DIR" && "$MOUNT_POINT" != "$DEFAULT_MOUNT_POINT" ]]; then
        REPO_DIR="${MOUNT_POINT%/}/backup"
    fi
}

find_repo_lv_path() {
    local lv_path="/dev/${VG_NAME}/${LV_NAME}"
    [[ -e "$lv_path" ]] && printf '%s\n' "$lv_path"
}

repo_lv_is_xfs() {
    local lv_path
    lv_path="$(find_repo_lv_path || true)"
    [[ -n "$lv_path" ]] || return 1
    blkid "$lv_path" 2>/dev/null | grep -q 'TYPE="xfs"'
}

repo_storage_present() {
    local lv_path
    lv_path="$(find_repo_lv_path || true)"
    [[ -n "$lv_path" ]] || return 1
    repo_lv_is_xfs
}

repo_path_ready() {
    local lv_path
    lv_path="$(find_repo_lv_path || true)"
    [[ -n "$lv_path" ]] || return 1
    repo_lv_is_xfs || return 1
    [[ -d "$MOUNT_POINT" ]] || return 1
    [[ -d "$REPO_DIR" ]] || return 1
    return 0
}

fspath_for_disk_nodes() {
    lsblk -nrpo NAME "$1" 2>/dev/null || true
}

device_belongs_to_disk() {
    local disk="$1"
    local dev="$2"
    local node
    while read -r node; do
        [[ "$node" == "$dev" ]] && return 0
    done < <(fspath_for_disk_nodes "$disk")
    return 1
}

ask_yes_no_default() {
    local prompt="$1"
    local default="$2"
    local answer

    [[ "$INTERACTIVE" == "yes" ]] || {
        printf '%s\n' "$default"
        return 0
    }

    while true; do
        if [[ "$default" == "yes" ]]; then
            ui_inline "${C_BOLD}${prompt}${C_RESET} [Y/n]: "
            read -r answer
            answer="${answer:-yes}"
        else
            ui_inline "${C_BOLD}${prompt}${C_RESET} [y/N]: "
            read -r answer
            answer="${answer:-no}"
        fi

        if is_yes "$answer"; then
            printf '%s\n' "yes"
            return 0
        fi
        if is_no "$answer"; then
            printf '%s\n' "no"
            return 0
        fi
        warn "Invalid answer. Use yes/no."
    done
}

ask_required_value() {
    local prompt="$1"
    local current="$2"
    local answer

    [[ "$INTERACTIVE" == "yes" ]] || {
        printf '%s\n' "$current"
        return 0
    }

    while true; do
        ui_inline "${C_BOLD}${prompt}${C_RESET} [${current}]: "
        read -r answer
        answer="${answer:-$current}"
        answer="$(normalize_ws "$answer")"
        [[ -n "$answer" ]] || {
            warn "The value cannot be empty."
            continue
        }
        printf '%s\n' "$answer"
        return 0
    done
}

need_value() {
    local option="$1"
    [[ $# -ge 2 ]] || die "Missing value for ${option}"
}

show_help() {
    cat <<EOF
Usage:
  $0 [options]

Phases:
  --phase prepare
      Prepares storage, user, SSH, firewall, and hardening settings
      compatible with the first Veeam connection.

  --phase post-attach-lockdown
      Run this after the first successful Veeam onboarding. It reduces
      user privileges, protects Veeam certificate directories, and can block SSH.

Modes:
  sudo $0
  sudo $0 --precheck-only
  sudo $0 --dry-run
  sudo $0 --non-interactive --disk /dev/sdb --ssh-net 192.168.10.0/24
  sudo $0 --phase post-attach-lockdown --veeam-user veeamrepo

Main options:
  --phase prepare|post-attach-lockdown
  --non-interactive
  --precheck-only
  --dry-run
  --disk auto|/dev/sdX
  --force-wipe yes|no
  --use-partition yes|no
  --vg NAME
  --lv NAME
  --lv-size SIZE|100%FREE
  --mount PATH
  --repo-dir PATH
  --veeam-user USER
  --veeam-group GROUP
  --ssh-net CIDR[,CIDR...]
  --veeam-net CIDR[,CIDR...]
  --extra-ufw-rules "rule1;rule2"
  --disable-ipv6 yes|no
  --enable-ufw yes|no
  --password-auth yes|no
  --auto-security-updates yes|no
  --auto-reboot-updates yes|no
  --harden-userns yes|no
  --grub-password yes|no
  --lock-root yes|no
  --reset-existing-veeam-password yes|no
  --disable-ssh-for-user-after-attach yes|no
  --disable-sshd-after-attach yes|no
  --help
EOF
}

show_help_full() {
    cat <<EOF
=================================================================
HARDENED REPOSITORY SAFER BOOTSTRAP
=================================================================

Why this version is safer:
  - no eval
  - disk wipe is limited to the selected target disk
  - the parent mount point remains traversable for the Veeam user
  - separate prepare and post-attach-lockdown phases
  - uses SSH and sudo drop-ins instead of overwriting full config files
  - stronger input, fstab, and LVM validation

Recommended flow:
  1. sudo $0 --dry-run
  2. sudo $0 --precheck-only
  3. sudo $0 --phase prepare
  4. Add the repository in Veeam using single-use credentials
  5. sudo $0 --phase post-attach-lockdown

Important note:
  Veeam documentation requires that the user used for the first connection is:
  - non-root
  - has a home directory
  - can elevate to root during the first onboarding if you want a persistent Data Mover
  Only after the repository has been added is it correct to remove sudo and, if desired, block SSH.
=================================================================
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --phase)
                need_value "$1" "$@"
                PHASE="$2"
                shift 2
                ;;
            --non-interactive)
                INTERACTIVE="no"
                shift
                ;;
            --precheck-only)
                PRECHECK_ONLY="yes"
                shift
                ;;
            --dry-run)
                DRY_RUN="yes"
                shift
                ;;
            --disk)
                need_value "$1" "$@"
                BACKUP_DISK="$2"
                shift 2
                ;;
            --force-wipe)
                need_value "$1" "$@"
                FORCE_WIPE="$2"
                shift 2
                ;;
            --use-partition)
                need_value "$1" "$@"
                USE_PARTITION="$2"
                shift 2
                ;;
            --vg)
                need_value "$1" "$@"
                VG_NAME="$2"
                shift 2
                ;;
            --lv)
                need_value "$1" "$@"
                LV_NAME="$2"
                shift 2
                ;;
            --lv-size)
                need_value "$1" "$@"
                LV_SIZE="$2"
                shift 2
                ;;
            --mount)
                need_value "$1" "$@"
                MOUNT_POINT="$2"
                shift 2
                ;;
            --repo-dir)
                need_value "$1" "$@"
                REPO_DIR="$2"
                shift 2
                ;;
            --veeam-user)
                need_value "$1" "$@"
                VEEAM_USER="$2"
                shift 2
                ;;
            --veeam-group)
                need_value "$1" "$@"
                VEEAM_GROUP="$2"
                shift 2
                ;;
            --ssh-net)
                need_value "$1" "$@"
                SSH_ALLOWED_NETS="$2"
                shift 2
                ;;
            --veeam-net)
                need_value "$1" "$@"
                VEEAM_ALLOWED_NETS="$2"
                shift 2
                ;;
            --extra-ufw-rules)
                need_value "$1" "$@"
                EXTRA_UFW_RULES="$2"
                shift 2
                ;;
            --disable-ipv6)
                need_value "$1" "$@"
                DISABLE_IPV6="$2"
                shift 2
                ;;
            --enable-ufw)
                need_value "$1" "$@"
                ENABLE_UFW="$2"
                shift 2
                ;;
            --password-auth)
                need_value "$1" "$@"
                ALLOW_PASSWORD_AUTH="$2"
                shift 2
                ;;
            --auto-security-updates)
                need_value "$1" "$@"
                ENABLE_AUTO_SECURITY_UPDATES="$2"
                shift 2
                ;;
            --auto-reboot-updates)
                need_value "$1" "$@"
                AUTO_REBOOT_UPDATES="$2"
                shift 2
                ;;
            --harden-userns)
                need_value "$1" "$@"
                HARDEN_USERNS="$2"
                shift 2
                ;;
            --grub-password)
                need_value "$1" "$@"
                SET_GRUB_PASSWORD="$2"
                shift 2
                ;;
            --lock-root)
                need_value "$1" "$@"
                LOCK_ROOT_PASSWORD="$2"
                shift 2
                ;;
            --reset-existing-veeam-password)
                need_value "$1" "$@"
                RESET_EXISTING_VEEAM_PASSWORD="$2"
                shift 2
                ;;
            --disable-ssh-for-user-after-attach)
                need_value "$1" "$@"
                DISABLE_SSH_FOR_USER_AFTER_ATTACH="$2"
                shift 2
                ;;
            --disable-sshd-after-attach)
                need_value "$1" "$@"
                DISABLE_SSHD_AFTER_ATTACH="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --help-full|--explain)
                show_help_full
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done
}

# --------------------[ Validation ]--------------------
validate_common_inputs() {
    [[ "$PHASE" == "prepare" || "$PHASE" == "post-attach-lockdown" ]] || die "Invalid phase: ${PHASE}"

    validate_linux_username "$VEEAM_USER" || die "Invalid username: ${VEEAM_USER}"
    validate_group_name "$VEEAM_GROUP" || die "Invalid group name: ${VEEAM_GROUP}"

    for value in \
        "$USE_PARTITION" \
        "$FORCE_WIPE" \
        "$DISABLE_IPV6" \
        "$ENABLE_UFW" \
        "$ALLOW_PASSWORD_AUTH" \
        "$ENABLE_AUTO_SECURITY_UPDATES" \
        "$AUTO_REBOOT_UPDATES" \
        "$HARDEN_USERNS" \
        "$SET_GRUB_PASSWORD" \
        "$LOCK_ROOT_PASSWORD" \
        "$RESET_EXISTING_VEEAM_PASSWORD" \
        "$DISABLE_SSH_FOR_USER_AFTER_ATTACH" \
        "$DISABLE_SSHD_AFTER_ATTACH"; do
        validate_yes_no "$value" || die "Invalid yes/no value: ${value}"
    done

    validate_extra_ufw_rules "$EXTRA_UFW_RULES" || die "Extra UFW rules cannot contain newlines."
}

validate_prepare_inputs() {
    maybe_autodetect_backup_disk
    autofill_repo_dir_from_mount

    validate_block_device "$BACKUP_DISK" || die "Invalid block device: ${BACKUP_DISK}"
    validate_mount_path "$MOUNT_POINT" || die "Invalid mount point: ${MOUNT_POINT}"
    validate_mount_path "$REPO_DIR" || die "Invalid repository directory: ${REPO_DIR}"
    validate_lv_size "$LV_SIZE" || die "Invalid LV_SIZE: ${LV_SIZE}"
    path_is_under_mountpoint "$REPO_DIR" "$MOUNT_POINT" || die "REPO_DIR must be under MOUNT_POINT."

    if [[ -n "$SSH_ALLOWED_NETS" ]]; then
        validate_net_csv "$SSH_ALLOWED_NETS" || die "Invalid SSH network list: ${SSH_ALLOWED_NETS}"
    fi

    if [[ -z "$VEEAM_ALLOWED_NETS" && -n "$SSH_ALLOWED_NETS" ]]; then
        VEEAM_ALLOWED_NETS="$SSH_ALLOWED_NETS"
    fi

    if [[ -n "$VEEAM_ALLOWED_NETS" ]]; then
        validate_net_csv "$VEEAM_ALLOWED_NETS" || die "Invalid Veeam network list: ${VEEAM_ALLOWED_NETS}"
    fi

    if [[ "$ENABLE_UFW" == "yes" && -z "$SSH_ALLOWED_NETS" ]]; then
        die "With UFW enabled you must specify at least --ssh-net."
    fi

    if [[ "$ENABLE_UFW" == "yes" && -z "$VEEAM_ALLOWED_NETS" ]]; then
        die "With UFW enabled you must specify --veeam-net, or let it inherit the value from --ssh-net."
    fi
}

# --------------------[ Wizard ]--------------------
pick_disk_interactive() {
    local disks=()
    local labels=()
    local idx=1
    local choice
    local disk size model

    while IFS='|' read -r disk size model; do
        [[ -n "$disk" ]] || continue
        disks+=("$disk")
        labels+=("${idx}) ${disk} - ${size} - ${model}")
        ((idx++))
    done < <(list_candidate_backup_disks)

    (( ${#disks[@]} > 0 )) || die "No candidate disk is available."

    ui "${C_BOLD}Select the dedicated repository disk:${C_RESET}"
    for label in "${labels[@]}"; do
        ui "  ${label}"
    done

    while true; do
        ui_inline "Choice [1-${#disks[@]}]: "
        read -r choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#disks[@]} )); then
            BACKUP_DISK="${disks[$((choice-1))]}"
            ok "Selected disk: ${BACKUP_DISK}"
            return 0
        fi

        warn "Invalid choice."
    done
}

wizard_start_menu() {
    banner
    cat <<EOF
1) Start prepare mode
2) Start post-attach-lockdown mode
3) Show quick help
4) Show extended help
5) Exit
EOF
    local choice
    while true; do
        read -r -p "Choice [1-5]: " choice
        case "$choice" in
            1) PHASE="prepare"; return 0 ;;
            2) PHASE="post-attach-lockdown"; return 0 ;;
            3) show_help; exit 0 ;;
            4) show_help_full; exit 0 ;;
            5) exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

wizard_prepare_values() {
    section "W1" "Guided configuration"

    maybe_autodetect_backup_disk
    SSH_ALLOWED_NETS="$(ask_required_value "Allowed SSH networks (comma-separated CIDRs)" "${SSH_ALLOWED_NETS:-192.168.10.0/24}")"
    VEEAM_ALLOWED_NETS="$(ask_required_value "Allowed Veeam traffic networks (port 6162 and failover 2500:3300)" "${VEEAM_ALLOWED_NETS:-$SSH_ALLOWED_NETS}")"
    BACKUP_DISK="$(ask_required_value "Dedicated repository disk" "${BACKUP_DISK:-/dev/sdb}")"
    MOUNT_POINT="$(ask_required_value "Mount point" "$MOUNT_POINT")"
    autofill_repo_dir_from_mount
    REPO_DIR="$(ask_required_value "Repository directory" "$REPO_DIR")"

    ui ""
    ui "${C_BOLD}Operational note:${C_RESET}"
    ui "  During the prepare phase, the user ${VEEAM_USER} keeps full sudo"
    ui "  to avoid issues during the first Veeam onboarding."
    ui "  The actual lock-down is applied only in the next phase."
    pause_enter
}

collect_grub_password_hash() {
    [[ "$SET_GRUB_PASSWORD" == "yes" ]] || return 0
    [[ "$INTERACTIVE" == "yes" ]] || {
        warn "GRUB password in non-interactive mode: provide a PBKDF2 hash by setting GRUB_PBKDF2_HASH in the script if you want to automate it."
        SET_GRUB_PASSWORD="no"
        return 0
    }

    section "W2" "GRUB password"
    info "Enter a grub.pbkdf2 hash already generated with grub-mkpasswd-pbkdf2."
    read -r -p "grub.pbkdf2 hash (leave blank to skip): " GRUB_PBKDF2_HASH
    if [[ -z "$GRUB_PBKDF2_HASH" ]]; then
        warn "No hash provided. GRUB protection disabled."
        SET_GRUB_PASSWORD="no"
    fi
}

# --------------------[ Prechecks ]--------------------
check_runtime_not_on_target_mount() {
    local target_mount="$1"
    local pwd_mount script_mount log_mount

    pwd_mount="$(path_mount_target "$PWD")"
    script_mount="$(path_mount_target "$0")"
    log_mount="$(path_mount_target "$LOG_DIR")"

    if [[ -n "$target_mount" && "$pwd_mount" == "$target_mount" ]]; then
        warn "The current working directory is on the target mount. Switching to /root."
        ensure_safe_workdir
    fi

    if [[ -n "$target_mount" && "$script_mount" == "$target_mount" ]]; then
        die "The script appears to be running from the target mount. Copy it to /root or /tmp and run it again."
    fi

    if [[ -n "$target_mount" && "$log_mount" == "$target_mount" ]]; then
        die "The log directory is on the target mount. Stopping to avoid I/O on the disk being initialized."
    fi
}

check_disk_is_not_system_disk() {
    local root_source pkname system_disk

    root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ -n "$root_source" ]] || {
        warn "Unable to determine the root device."
        return 0
    }

    pkname="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
    [[ -n "$pkname" ]] || return 0

    system_disk="/dev/${pkname}"
    [[ "$BACKUP_DISK" != "$system_disk" ]] || die "The selected disk (${BACKUP_DISK}) appears to be the system disk."
}

device_has_existing_signatures() {
    wipefs -n "$1" 2>/dev/null | tail -n +2 | grep -q .
}

check_time_sync_health() {
    local ntp_sync local_rtc timezone

    if ! cmd_exists timedatectl; then
        warn "timedatectl is not available: unable to verify time synchronization and RTC settings."
        return 0
    fi

    ntp_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    local_rtc="$(timedatectl show -p LocalRTC --value 2>/dev/null || true)"
    timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"

    if [[ "$ntp_sync" == "yes" ]]; then
        ok "NTP synchronization is active."
    else
        warn "NTP does not appear to be synchronized. Reliable time synchronization is strongly recommended for Veeam immutability."
    fi

    if [[ "$local_rtc" == "no" ]]; then
        ok "RTC is configured to UTC."
    elif [[ -n "$local_rtc" ]]; then
        warn "RTC does not appear to be set to UTC. Veeam recommends UTC RTC for more accurate timeshift detection."
    fi

    [[ -n "$timezone" ]] && info "Configured timezone: ${timezone}"
}

prechecks_prepare() {
    section "0" "Prepare precheck"

    require_root
    require_cmd apt
    require_cmd awk
    require_cmd blkid
    require_cmd blockdev
    require_cmd chpasswd
    require_cmd cp
    require_cmd date
    require_cmd findmnt
    require_cmd getent
    require_cmd gpasswd
    require_cmd grep
    require_cmd id
    require_cmd install
    require_cmd lsblk
    require_cmd mount
    require_cmd passwd
    require_cmd sed
    require_cmd systemctl
    require_cmd tee
    require_cmd udevadm
    require_cmd umount
    require_cmd useradd
    require_cmd usermod
    require_cmd wipefs

    load_os_release
    info "Detected system: ${OS_PRETTY_NAME:-unknown}"
    ubuntu_supported || die "This script supports Ubuntu 22.04 and 24.04."

    ensure_safe_workdir
    check_runtime_not_on_target_mount "$MOUNT_POINT"
    check_disk_is_not_system_disk

    info "Current target disk layout:"
    lsblk -f "$BACKUP_DISK" | tee -a "$MAIN_LOG" >/dev/null
    lsblk -f "$BACKUP_DISK" >&2 || true

    if device_has_existing_signatures "$BACKUP_DISK"; then
        if repo_storage_present; then
            ok "Disk signatures are present, but they appear to belong to the existing repository storage."
        elif [[ "$FORCE_WIPE" == "yes" ]]; then
            warn "Disk signatures are present. They will be removed because FORCE_WIPE=yes."
        else
            die "Disk signatures or partitions are present on the target disk. For safety, use --force-wipe yes or choose a clean disk."
        fi
    else
        ok "No existing signatures were detected on the target disk."
    fi

    if lsblk -nrpo NAME,MOUNTPOINT "$BACKUP_DISK" | awk 'NF > 1 && $2 != "" {print}' | grep -q .; then
        if [[ "$FORCE_WIPE" == "yes" ]]; then
            warn "The target disk appears to be mounted or in use. Cleanup will attempt to unmount it."
        else
            warn "The target disk or one of its partitions appears to be mounted or in use."
        fi
    else
        ok "The target disk does not appear to be mounted."
    fi

    if mountpoint_in_use "$MOUNT_POINT"; then
        warn "The mount point ${MOUNT_POINT} is already mounted."
    else
        ok "The mount point ${MOUNT_POINT} is not mounted."
    fi

    if [[ -d "$MOUNT_POINT" ]] && dir_nonempty "$MOUNT_POINT"; then
        warn "The directory ${MOUNT_POINT} already exists and is not empty."
    fi

    if [[ -d "$REPO_DIR" ]] && dir_nonempty "$REPO_DIR"; then
        warn "The directory ${REPO_DIR} already exists and is not empty."
    fi

    if repo_path_ready; then
        ok "Repository storage already present: VG/LV/XFS/directories detected."
    fi

    if [[ -d /sys/firmware/efi ]]; then
        ok "System booted in UEFI mode."
    else
        warn "System is NOT booted in UEFI mode."
    fi

    if cmd_exists mokutil; then
        if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
            ok "Secure Boot appears to be enabled."
        else
            warn "Secure Boot does not appear to be enabled."
        fi
    else
        warn "mokutil is not installed: Secure Boot status was not checked."
    fi

    check_time_sync_health

    ok "Prepare precheck completed."
}

prechecks_lockdown() {
    section "0" "Post-attach lockdown precheck"

    require_root
    require_cmd gpasswd
    require_cmd id
    require_cmd install
    require_cmd sshd
    require_cmd systemctl
    require_cmd visudo

    getent passwd "$VEEAM_USER" >/dev/null 2>&1 || die "The user ${VEEAM_USER} does not exist."
    info "Target user: ${VEEAM_USER}"

    if [[ ! -d /opt/veeam/transport/certs ]]; then
        warn "The directory /opt/veeam/transport/certs does not exist yet."
        warn "This usually means the first Data Mover deployment has not happened yet."
    else
        ok "Veeam certificate directory detected."
    fi

    ok "Post-attach lockdown precheck completed."
}

# --------------------[ Packages ]--------------------
install_packages() {
    section "1" "Package installation"

    local packages=(
        lvm2
        xfsprogs
        gdisk
        parted
        openssh-server
        unattended-upgrades
        ufw
        rsyslog
        auditd
        audispd-plugins
        apparmor-utils
        mokutil
    )
    local missing=()
    local pkg

    for pkg in "${packages[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    if (( ${#missing[@]} == 0 )); then
        ok "Required packages are already installed."
        return 0
    fi

    run_or_die "APT update" apt update
    run_or_die "Install required packages" apt install -y "${missing[@]}"
}

ensure_post_package_commands() {
    local cmd
    for cmd in parted sgdisk pvcreate vgcreate lvcreate mkfs.xfs pvs vgs lvs partprobe xfs_info ufw visudo sshd augenrules auditctl; do
        require_cmd "$cmd"
    done
}

# --------------------[ Storage ]--------------------
get_vgs_for_disk() {
    local disk="$1"
    local pv vg
    while read -r pv vg; do
        [[ -n "${pv:-}" && -n "${vg:-}" ]] || continue
        if device_belongs_to_disk "$disk" "$pv"; then
            printf '%s\n' "$vg"
        fi
    done < <(pvs --noheadings --separator '|' -o pv_name,vg_name 2>/dev/null | sed 's/^[[:space:]]*//')
}

wipe_target_disk_safely() {
    section "2" "Safe target disk cleanup"

    local disk="$1"
    local part mountp dev vg lv pv other_pv count disk_size seek
    local -a processed_vgs=()

    ensure_safe_workdir
    check_runtime_not_on_target_mount "$MOUNT_POINT"
    check_disk_is_not_system_disk

    while read -r part mountp; do
        [[ -n "${mountp:-}" ]] || continue
        run "Unmount ${part}" umount -f "$part"
    done < <(lsblk -nrpo NAME,MOUNTPOINT "$disk" | tail -n +2)

    while read -r dev _; do
        [[ -n "${dev:-}" ]] || continue
        if device_belongs_to_disk "$disk" "$dev"; then
            run "Swapoff ${dev}" swapoff "$dev" || true
        fi
    done < <(swapon --noheadings --raw 2>/dev/null || true)

    while read -r vg; do
        [[ -n "${vg:-}" ]] || continue
        if printf '%s\n' "${processed_vgs[@]}" | grep -Fxq "$vg"; then
            continue
        fi
        processed_vgs+=("$vg")

        count=0
        while read -r other_pv; do
            other_pv="$(normalize_ws "$other_pv")"
            [[ -n "$other_pv" ]] || continue
            ((count++))
            device_belongs_to_disk "$disk" "$other_pv" || die "VG ${vg} also uses PV ${other_pv}, which is outside the target disk. Stopping for safety."
        done < <(pvs --noheadings -o pv_name "$vg" 2>/dev/null || true)

        (( count > 0 )) || continue

        while read -r lv; do
            lv="$(normalize_ws "$lv")"
            [[ -n "$lv" ]] || continue
            run_or_die "Remove LV ${vg}/${lv}" lvremove -f "/dev/${vg}/${lv}"
        done < <(lvs --noheadings -o lv_name "$vg" 2>/dev/null || true)

        run_or_die "Deactivate VG ${vg}" vgchange -an "$vg"
        run_or_die "Remove VG ${vg}" vgremove -f "$vg"
    done < <(get_vgs_for_disk "$disk" | sort -u)

    while read -r pv; do
        pv="$(normalize_ws "$pv")"
        [[ -n "$pv" ]] || continue
        if device_belongs_to_disk "$disk" "$pv"; then
            run "Remove PV ${pv}" pvremove -ff -y "$pv" || true
        fi
    done < <(pvs --noheadings -o pv_name 2>/dev/null || true)

    while read -r dev; do
        [[ -n "${dev:-}" ]] || continue
        [[ "$dev" == "$disk" ]] && continue
        run "Wipe signatures ${dev}" wipefs -af "$dev" || true
    done < <(lsblk -nrpo NAME "$disk" | tail -n +2)

    run "Wipe signatures ${disk}" wipefs -af "$disk" || true
    run "Zap GPT/MBR ${disk}" sgdisk --zap-all "$disk" || true

    if [[ "$DRY_RUN" != "yes" ]]; then
        disk_size="$(blockdev --getsize64 "$disk")"
        run "Zero first 16MiB ${disk}" dd if=/dev/zero of="$disk" bs=1M count=16 conv=fsync status=none
        seek=$(( (disk_size / 1048576) - 16 ))
        if (( seek > 0 )); then
            run "Zero last 16MiB ${disk}" dd if=/dev/zero of="$disk" bs=1M seek="$seek" count=16 conv=fsync status=none
        fi
    else
        info "DRY-RUN skip zeroing first/last sectors on ${disk}"
    fi

    run "Reload partition table ${disk}" partprobe "$disk" || true
    run "Wait for udev" udevadm settle || true
}

create_lvm() {
    section "3" "Storage LVM"

    local lv_path="/dev/${VG_NAME}/${LV_NAME}"
    local pv_target
    local -a lvcreate_args

    if [[ -e "$lv_path" ]]; then
        repo_lv_is_xfs || die "LV ${lv_path} exists but does not appear to be XFS. Refusing to continue automatically."
        ok "LV ${lv_path} already exists."
        return 0
    fi

    if [[ "$FORCE_WIPE" == "yes" ]]; then
        wipe_target_disk_safely "$BACKUP_DISK"
    fi

    if [[ "$USE_PARTITION" == "yes" ]]; then
        detect_partition_name
        run_or_die "Create GPT label" parted -s "$BACKUP_DISK" mklabel gpt
        run_or_die "Create LVM partition" parted -s -a optimal "$BACKUP_DISK" mkpart primary 1MiB 100%
        run_or_die "Set LVM flag" parted -s "$BACKUP_DISK" set 1 lvm on
        run_or_die "Reload partition table" partprobe "$BACKUP_DISK"
        run_or_die "Wait udev settle" udevadm settle
        [[ -b "$PARTITION_NAME" ]] || die "Expected partition ${PARTITION_NAME} did not appear."
        pv_target="$PARTITION_NAME"
    else
        pv_target="$BACKUP_DISK"
    fi

    if ! pvs "$pv_target" >/dev/null 2>&1; then
        run_or_die "Create PV ${pv_target}" pvcreate -ff -y "$pv_target"
    else
        ok "PV ${pv_target} already exists."
    fi

    if ! vgs "$VG_NAME" >/dev/null 2>&1; then
        run_or_die "Create VG ${VG_NAME}" vgcreate "$VG_NAME" "$pv_target"
    else
        die "VG ${VG_NAME} already exists but the expected LV is not ready. Fix the VG name or clean it up manually."
    fi

    lvcreate_args=(-n "$LV_NAME")
    if [[ "$LV_SIZE" == *%* ]]; then
        lvcreate_args+=(-l "$LV_SIZE")
    else
        lvcreate_args+=(-L "$LV_SIZE")
    fi
    lvcreate_args+=("$VG_NAME")
    run_or_die "Create LV ${LV_NAME}" lvcreate "${lvcreate_args[@]}"
}

create_xfs() {
    section "4" "Filesystem XFS"

    local lv_path="/dev/${VG_NAME}/${LV_NAME}"

    if repo_lv_is_xfs; then
        ok "XFS filesystem already exists on ${lv_path}."
        return 0
    fi

    if blkid "$lv_path" 2>/dev/null | grep -q 'TYPE='; then
        die "The device ${lv_path} already has a non-XFS filesystem. Stopping for safety."
    fi

    run_or_die "Create XFS ${lv_path}" mkfs.xfs -f -L "$FS_LABEL" -m reflink=1,crc=1 "$lv_path"
}

ensure_fstab_entry() {
    local lv_path="$1"
    local uuid existing
    uuid="$(blkid -s UUID -o value "$lv_path")"
    [[ -n "$uuid" ]] || die "Unable to read the UUID of ${lv_path}."

    existing="$(awk -v target="$MOUNT_POINT" '$1 !~ /^#/ && $2 == target {print $0}' /etc/fstab 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        if grep -Fq "UUID=${uuid}" <<< "$existing"; then
            ok "fstab entry already present for ${MOUNT_POINT}."
            return 0
        fi
        die "An fstab entry already exists for ${MOUNT_POINT}, but it does not point to the expected LV: ${existing}"
    fi

    if grep -Fq "UUID=${uuid}" /etc/fstab 2>/dev/null; then
        die "UUID ${uuid} is already present in /etc/fstab on another line. Verify it manually."
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN add fstab: UUID=${uuid} ${MOUNT_POINT} xfs ${FSTAB_OPTS} 0 0"
        return 0
    fi

    backup_file /etc/fstab
    printf 'UUID=%s %s xfs %s 0 0\n' "$uuid" "$MOUNT_POINT" "$FSTAB_OPTS" >> /etc/fstab
}

mount_repo() {
    section "5" "Mount repository"

    local lv_path="/dev/${VG_NAME}/${LV_NAME}"
    run_or_die "Create mount point ${MOUNT_POINT}" mkdir -p "$MOUNT_POINT"
    ensure_fstab_entry "$lv_path"

    if ! mountpoint_in_use "$MOUNT_POINT"; then
        run_or_die "Mount ${MOUNT_POINT}" mount "$MOUNT_POINT"
    else
        ok "${MOUNT_POINT} is already mounted."
    fi

    run_or_die "Verify mount ${MOUNT_POINT}" findmnt "$MOUNT_POINT"
    run_or_die "Verify XFS ${MOUNT_POINT}" xfs_info "$MOUNT_POINT"
    run_or_die "Create repository dir ${REPO_DIR}" mkdir -p "$REPO_DIR"
}

# --------------------[ Account ]--------------------
user_password_status() {
    passwd -S "$1" 2>/dev/null | awk '{print $2}' || true
}

create_veeam_user_prepare() {
    section "6" "Veeam user for first onboarding"

    if ! getent group "$VEEAM_GROUP" >/dev/null 2>&1; then
        run_or_die "Create group ${VEEAM_GROUP}" groupadd "$VEEAM_GROUP"
    else
        ok "Group ${VEEAM_GROUP} already exists."
    fi

    if ! id "$VEEAM_USER" >/dev/null 2>&1; then
        run_or_die "Create user ${VEEAM_USER}" useradd -m -d "/home/${VEEAM_USER}" -s /bin/bash -g "$VEEAM_GROUP" "$VEEAM_USER"
        VEEAM_PASSWORD="$(generate_random_password)"
        if [[ "$DRY_RUN" == "yes" ]]; then
            info "DRY-RUN set password for ${VEEAM_USER}"
        else
            printf '%s:%s\n' "$VEEAM_USER" "$VEEAM_PASSWORD" | chpasswd
        fi
        VEEAM_USER_WAS_CREATED="yes"
    else
        ok "User ${VEEAM_USER} already exists."
        VEEAM_USER_WAS_CREATED="no"
        if [[ "$RESET_EXISTING_VEEAM_PASSWORD" == "yes" ]]; then
            VEEAM_PASSWORD="$(generate_random_password)"
            if [[ "$DRY_RUN" == "yes" ]]; then
                info "DRY-RUN reset password for ${VEEAM_USER}"
            else
                printf '%s:%s\n' "$VEEAM_USER" "$VEEAM_PASSWORD" | chpasswd
            fi
            info "Password regenerated for the existing user."
        else
            case "$(user_password_status "$VEEAM_USER")" in
                L|NP)
                    warn "The user ${VEEAM_USER} exists but appears to have a locked or missing password."
                    warn "For the first onboarding with single-use credentials, you may need to set a valid password."
                    ;;
            esac
        fi
    fi

    run_or_die "Add ${VEEAM_USER} to the sudo group for the first attach" usermod -aG sudo "$VEEAM_USER"

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN set ownership/permissions on ${MOUNT_POINT} and ${REPO_DIR}"
    else
        chown root:root "$MOUNT_POINT"
        chmod 0755 "$MOUNT_POINT"
        chown -R "${VEEAM_USER}:${VEEAM_GROUP}" "$REPO_DIR"
        chmod 0700 "$REPO_DIR"
    fi

    if [[ "$DRY_RUN" != "yes" && -n "$VEEAM_PASSWORD" ]]; then
        install -d -m 0700 /root
        write_file "/root/.veeam_repo_credentials_${TIMESTAMP}" "0600" "root" "root" <<EOF
User: ${VEEAM_USER}
Password: ${VEEAM_PASSWORD}
Created: $(date '+%F %T')
Purpose: initial Veeam single-use credentials
EOF
    fi

    ok "User ${VEEAM_USER} is ready for the first onboarding."
}

# --------------------[ Hardening prepare ]--------------------
configure_auto_updates() {
    section "7" "Automatic updates"

    [[ "$ENABLE_AUTO_SECURITY_UPDATES" == "yes" ]] || {
        warn "Automatic updates left disabled by choice."
        return 0
    }

    run_or_die "Enable unattended-upgrades" dpkg-reconfigure -f noninteractive unattended-upgrades

    write_file "/etc/apt/apt.conf.d/20auto-upgrades" "0644" "root" "root" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

    write_file "/etc/apt/apt.conf.d/52auto-reboot-veeam" "0644" "root" "root" <<EOF
Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT_UPDATES}";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
EOF
}

configure_banners() {
    section "8" "Legal banners"

    write_file "/etc/issue.net" "0644" "root" "root" <<'EOF'
******************************************************
*                                                    *
*              Authorized Access Only                *
*                                                    *
******************************************************

This system is for authorized use only.
Unauthorized access or use is prohibited.
Activities may be monitored and recorded.
EOF

    write_file "/etc/issue" "0644" "root" "root" < /etc/issue.net
    write_file "/etc/motd" "0644" "root" "root" < /etc/issue.net
}

configure_kernel_sysctl() {
    section "9" "Kernel hardening"

    local file="/etc/sysctl.d/60-veeam-hardening.conf"
    local enable_userns_key="no"

    if [[ "$HARDEN_USERNS" == "yes" ]]; then
        if [[ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]]; then
            enable_userns_key="yes"
        else
            warn "kernel.apparmor_restrict_unprivileged_userns is not supported on this kernel. Skipping."
        fi
    fi

    write_file "$file" "0644" "root" "root" <<EOF
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOF

    if [[ "$DRY_RUN" != "yes" ]]; then
        if [[ "$DISABLE_IPV6" == "yes" ]]; then
            {
                printf '%s\n' 'net.ipv6.conf.all.disable_ipv6 = 1'
                printf '%s\n' 'net.ipv6.conf.default.disable_ipv6 = 1'
                printf '%s\n' 'net.ipv6.conf.lo.disable_ipv6 = 1'
            } >> "$file"
        fi
        if [[ "$enable_userns_key" == "yes" ]]; then
            printf '%s\n' 'kernel.apparmor_restrict_unprivileged_userns = 1' >> "$file"
        fi
    fi

    run_or_die "Apply sysctl settings" sysctl --system
}

ensure_sshd_include_dropins() {
    local include_line='Include /etc/ssh/sshd_config.d/*.conf'
    grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$' /etc/ssh/sshd_config && return 0

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN prepend SSH include to /etc/ssh/sshd_config"
        return 0
    fi

    backup_file /etc/ssh/sshd_config
    {
        printf '%s\n' "$include_line"
        cat /etc/ssh/sshd_config
    } > /etc/ssh/sshd_config.new
    install -o root -g root -m 0600 /etc/ssh/sshd_config.new /etc/ssh/sshd_config
    rm -f /etc/ssh/sshd_config.new
}

configure_ssh_prepare() {
    section "10" "SSH configuration for first attach"

    local password_auth="yes"
    [[ "$ALLOW_PASSWORD_AUTH" == "yes" ]] || password_auth="no"

    ensure_sshd_include_dropins
    install -d -m 0755 /etc/ssh/sshd_config.d

    write_file "/etc/ssh/sshd_config.d/90-veeam-hardening.conf" "0644" "root" "root" <<EOF
PermitRootLogin no
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 4
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
Banner /etc/issue.net
EOF

    run_or_die "Validate SSH configuration" sshd -t
    run_or_die "Enable SSH service" systemctl enable ssh
    run_or_die "Restart SSH service" systemctl restart ssh
}

configure_sudo_logging() {
    section "11" "Sudo logging"

    write_file "/etc/sudoers.d/01-veeam-logging" "0440" "root" "root" <<'EOF'
Defaults logfile=/var/log/sudo.log
Defaults log_input,log_output
Defaults use_pty
Defaults env_reset,timestamp_timeout=15
EOF

    run_or_die "Validate sudoers logging" visudo -c -f /etc/sudoers.d/01-veeam-logging
}

configure_auditd() {
    section "12" "Auditd"

    write_file "/etc/audit/rules.d/50-veeam-hardening.rules" "0640" "root" "root" <<EOF
-D
-b 8192
-f 1
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w ${REPO_DIR} -p wa -k veeamrepo
EOF

    backup_file /etc/audit/auditd.conf
    set_kv_in_file "max_log_file" "50" /etc/audit/auditd.conf
    set_kv_in_file "max_log_file_action" "ROTATE" /etc/audit/auditd.conf
    set_kv_in_file "num_logs" "10" /etc/audit/auditd.conf
    set_kv_in_file "space_left_action" "SYSLOG" /etc/audit/auditd.conf

    run_or_die "Enable auditd" systemctl enable --now auditd
    run_or_die "Load audit rules" augenrules --load
}

configure_rsyslog_journal() {
    section "13" "Rsyslog e journald"

    write_file "/etc/rsyslog.d/90-veeam-hardening.conf" "0644" "root" "root" <<'EOF'
*.emerg :omusrmsg:*
auth,authpriv.* /var/log/auth.log
EOF

    write_file "/etc/logrotate.d/sudo" "0644" "root" "root" <<'EOF'
/var/log/sudo.log {
  rotate 12
  monthly
  compress
  missingok
  notifempty
  create 0640 root adm
}
EOF

    backup_file /etc/systemd/journald.conf
    set_kv_in_file "Storage" "persistent" /etc/systemd/journald.conf
    set_kv_in_file "SystemMaxUse" "250M" /etc/systemd/journald.conf

    run_or_die "Enable rsyslog" systemctl enable --now rsyslog
    run_or_die "Restart rsyslog" systemctl restart rsyslog
    run_or_die "Restart journald" systemctl restart systemd-journald

    if [[ "$DRY_RUN" != "yes" ]]; then
        touch /var/log/sudo.log
        chmod 0640 /var/log/sudo.log
        chown root:adm /var/log/sudo.log
    fi
}

configure_apparmor() {
    section "14" "AppArmor"
    run "Check AppArmor status" aa-status || true
    info "AppArmor is left in enforcing mode when already present."
}

ensure_ufw_rule() {
    local desc="$1"
    shift
    run_or_die "$desc" ufw "$@"
}

configure_ufw() {
    section "15" "Firewall UFW"

    [[ "$ENABLE_UFW" == "yes" ]] || {
        info "UFW is left disabled by configuration."
        return 0
    }

    local ufw_active="no"
    local net rule

    ufw status 2>/dev/null | grep -q "Status: active" && ufw_active="yes"

    if [[ "$ufw_active" == "no" ]]; then
        run_or_die "UFW default deny incoming" ufw default deny incoming
        run_or_die "UFW default allow outgoing" ufw default allow outgoing
    else
        info "UFW is already active: no global reset will be performed, only the required rules will be added."
    fi

    ensure_ufw_rule "Allow loopback inbound" allow in on lo
    ensure_ufw_rule "Allow loopback outbound" allow out on lo

    IFS=',' read -r -a ssh_nets <<< "$SSH_ALLOWED_NETS"
    for net in "${ssh_nets[@]}"; do
        net="$(normalize_ws "$net")"
        [[ -n "$net" ]] || continue
        ensure_ufw_rule "Allow SSH from ${net}" allow from "$net" to any port 22 proto tcp
    done

    IFS=',' read -r -a veeam_nets <<< "$VEEAM_ALLOWED_NETS"
    for net in "${veeam_nets[@]}"; do
        net="$(normalize_ws "$net")"
        [[ -n "$net" ]] || continue
        ensure_ufw_rule "Allow Veeam transport 6162 from ${net}" allow from "$net" to any port 6162 proto tcp
        ensure_ufw_rule "Allow Veeam failover 2500:3300 from ${net}" allow from "$net" to any port 2500:3300 proto tcp
    done

    if [[ -n "$EXTRA_UFW_RULES" ]]; then
        IFS=';' read -r -a rules <<< "$EXTRA_UFW_RULES"
        for rule in "${rules[@]}"; do
            rule="$(normalize_ws "$rule")"
            [[ -n "$rule" ]] || continue
            local -a rule_parts=()
            read -r -a rule_parts <<< "$rule"
            (( ${#rule_parts[@]} > 0 )) || continue
            run_or_die "Apply extra UFW rule: ${rule}" ufw "${rule_parts[@]}"
        done
    fi

    if [[ "$ufw_active" == "no" ]]; then
        run_or_die "Enable UFW" ufw --force enable
    fi
}

configure_grub_password() {
    section "16" "GRUB protection"

    [[ "$SET_GRUB_PASSWORD" == "yes" ]] || {
        info "GRUB protection not requested."
        return 0
    }

    [[ -n "$GRUB_PBKDF2_HASH" || "$DRY_RUN" == "yes" ]] || die "Missing GRUB PBKDF2 hash."

    write_file "/etc/grub.d/40_custom" "0755" "root" "root" <<EOF
set superusers="root"
password_pbkdf2 root ${GRUB_PBKDF2_HASH}
EOF

    run_or_die "Update GRUB" update-grub
}

lock_root_password_if_requested() {
    section "17" "Root password"

    [[ "$LOCK_ROOT_PASSWORD" == "yes" ]] || {
        info "Root password left unchanged by configuration."
        return 0
    }

    run_or_die "Lock root password" passwd -l root
}

# --------------------[ Post attach lockdown ]--------------------
configure_veeam_certs_permissions() {
    section "20" "Veeam certificates"

    if [[ ! -d /opt/veeam/transport/certs ]]; then
        warn "Directory /opt/veeam/transport/certs was not found. Skipping this step."
        return 0
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN chown ${VEEAM_USER}:${VEEAM_GROUP} /opt/veeam/transport/certs"
        info "DRY-RUN chmod 700 /opt/veeam/transport/certs"
        return 0
    fi

    chown "${VEEAM_USER}:${VEEAM_GROUP}" /opt/veeam/transport/certs
    chmod 0700 /opt/veeam/transport/certs
    ok "Veeam certificate permissions aligned with the documentation."
}

configure_veeam_reduced_sudo() {
    section "21" "Reduce Veeam user privileges"

    write_file "/etc/sudoers.d/99-veeam-limited" "0440" "root" "root" <<EOF
${VEEAM_USER} ALL = (root) NOPASSWD:NOEXEC: /usr/sbin/reboot, /usr/sbin/shutdown, /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff
EOF

    run_or_die "Validate limited sudoers" visudo -c -f /etc/sudoers.d/99-veeam-limited
    run_or_die "Remove ${VEEAM_USER} from sudo group" gpasswd -d "$VEEAM_USER" sudo
}

lockdown_ssh_after_attach() {
    section "22" "Lockdown SSH post-attach"

    ensure_sshd_include_dropins
    install -d -m 0755 /etc/ssh/sshd_config.d

    if [[ "$DISABLE_SSH_FOR_USER_AFTER_ATTACH" == "yes" ]]; then
        write_file "/etc/ssh/sshd_config.d/99-veeamrepo-deny.conf" "0644" "root" "root" <<EOF
DenyUsers ${VEEAM_USER}
EOF
        run_or_die "Validate SSH configuration" sshd -t
        run_or_die "Reload SSH service" systemctl reload ssh
        ok "SSH access blocked for ${VEEAM_USER}."
    else
        info "Per-user SSH lock is disabled by configuration."
    fi

    if [[ "$DISABLE_SSHD_AFTER_ATTACH" == "yes" ]]; then
        run_or_die "Disable SSH service" systemctl disable --now ssh
    fi
}

# --------------------[ State and summary ]--------------------
persist_prepare_state() {
    section "30" "Persist state"

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN skip state file ${TIMESTAMP_FILE}"
        return 0
    fi

    install -d -m 0755 /etc/veeam-hardened-repo
    write_file "$TIMESTAMP_FILE" "0600" "root" "root" <<EOF
VEEAM_USER='${VEEAM_USER}'
VEEAM_GROUP='${VEEAM_GROUP}'
MOUNT_POINT='${MOUNT_POINT}'
REPO_DIR='${REPO_DIR}'
BACKUP_DISK='${BACKUP_DISK}'
VG_NAME='${VG_NAME}'
LV_NAME='${LV_NAME}'
SSH_ALLOWED_NETS='${SSH_ALLOWED_NETS}'
VEEAM_ALLOWED_NETS='${VEEAM_ALLOWED_NETS}'
PREPARED_AT='$(date '+%F %T')'
EOF
}

show_prepare_summary() {
    section "31" "Prepare summary"

    cat <<EOF >&2
  OS target                 : ${OS_PRETTY_NAME}
  Repository disk           : ${BACKUP_DISK}
  VG / LV                   : ${VG_NAME} / ${LV_NAME}
  Mount point               : ${MOUNT_POINT}
  Repository dir            : ${REPO_DIR}
  Veeam user                : ${VEEAM_USER}
  Veeam group               : ${VEEAM_GROUP}
  SSH allowed networks      : ${SSH_ALLOWED_NETS:-<not set>}
  Veeam allowed networks    : ${VEEAM_ALLOWED_NETS:-<not set>}
  SSH password auth         : ${ALLOW_PASSWORD_AUTH}
  UFW                       : ${ENABLE_UFW}
  Auto security updates     : ${ENABLE_AUTO_SECURITY_UPDATES}
  Auto reboot updates       : ${AUTO_REBOOT_UPDATES}
  Lock root password        : ${LOCK_ROOT_PASSWORD}
  Log directory             : ${LOG_DIR}
EOF

    ui ""
    ui "${C_BOLD}Important operational notes:${C_RESET}"
    ui "  1. The parent mount point ${MOUNT_POINT} remains root:root 755."
    ui "     This avoids blocking traversal to ${REPO_DIR}."
    ui "  2. The repository directory ${REPO_DIR} is ${VEEAM_USER}:${VEEAM_GROUP} 700,"
    ui "     as recommended by Veeam for the backup path."
    ui "  3. ${VEEAM_USER} remains in the sudo group during this phase,"
    ui "     so the initial onboarding with single-use credentials does not break."
}

show_next_steps_prepare() {
    section "32" "Next steps"

    cat <<EOF >&2
1. In Veeam Backup & Replication, add the Linux server/repository using:
   - single-use credentials
   - non-root user: ${VEEAM_USER}
   - home directory: /home/${VEEAM_USER}

2. If you want the Data Mover to remain persistent, temporarily keep root elevation available.
   This script intentionally leaves it available to avoid issues during the first attach.

3. After the first successful attach, run:
   sudo $0 --phase post-attach-lockdown --veeam-user ${VEEAM_USER} --veeam-group ${VEEAM_GROUP}

4. If a new password was generated, you can find it in:
   /root/.veeam_repo_credentials_${TIMESTAMP}
EOF
}

show_lockdown_summary() {
    section "33" "Post-attach lockdown summary"

    cat <<EOF >&2
  Veeam user                : ${VEEAM_USER}
  Full sudo                 : removed
  Limited sudo              : active for reboot/shutdown
  Veeam cert dir            : /opt/veeam/transport/certs protected when present
  SSH for Veeam user        : ${DISABLE_SSH_FOR_USER_AFTER_ATTACH}
  Entire SSHD service       : ${DISABLE_SSHD_AFTER_ATTACH}
  Log directory             : ${LOG_DIR}
EOF

    ui ""
    warn "After sudo removal, ${VEEAM_USER} will no longer have administrative privileges."
    warn "For future privileged maintenance, use a separate admin account or local console access."
}

show_credentials_if_any() {
    section "34" "Veeam credentials"

    if [[ -n "$VEEAM_PASSWORD" ]]; then
        cat <<EOF >&2
User: ${VEEAM_USER}
Password: ${VEEAM_PASSWORD}

Also saved in:
  /root/.veeam_repo_credentials_${TIMESTAMP}
EOF
    else
        ui "No new password was generated during this run."
    fi
}

confirm_destruction_if_needed() {
    [[ "$PHASE" == "prepare" ]] || return 0
    [[ "$FORCE_WIPE" == "yes" ]] || return 0
    [[ "$INTERACTIVE" == "yes" ]] || return 0

    section "C1" "Destructive action confirmation"
    warn "This operation will initialize disk ${BACKUP_DISK}."
    local typed
    read -r -p "To confirm, type exactly: WIPE ${BACKUP_DISK}: " typed
    [[ "$typed" == "WIPE ${BACKUP_DISK}" ]] || die "Invalid confirmation. Operation cancelled."
    ok "Destructive action confirmed."
}

final_confirm() {
    [[ "$INTERACTIVE" == "yes" ]] || return 0
    local proceed
    proceed="$(ask_yes_no_default "Do you want to continue?" "no")"
    [[ "$proceed" == "yes" ]] || die "Operation cancelled by the user."
}

# --------------------[ Main flows ]--------------------
prepare_flow() {
    if [[ "$INTERACTIVE" == "yes" ]]; then
        wizard_prepare_values
        collect_grub_password_hash
    fi

    validate_prepare_inputs
    banner
    show_prepare_summary
    confirm_destruction_if_needed
    final_confirm
    prechecks_prepare

    if [[ "$PRECHECK_ONLY" == "yes" ]]; then
        info "Precheck-only mode: no changes were applied."
        return 0
    fi

    install_packages
    ensure_post_package_commands
    create_lvm
    create_xfs
    mount_repo
    create_veeam_user_prepare
    configure_auto_updates
    configure_banners
    configure_kernel_sysctl
    configure_ssh_prepare
    configure_sudo_logging
    configure_auditd
    configure_rsyslog_journal
    configure_apparmor
    configure_ufw
    configure_grub_password
    lock_root_password_if_requested
    persist_prepare_state
    show_credentials_if_any
    show_next_steps_prepare
}

post_attach_lockdown_flow() {
    banner
    prechecks_lockdown

    if [[ "$PRECHECK_ONLY" == "yes" ]]; then
        info "Precheck-only mode: no changes were applied."
        return 0
    fi

    final_confirm
    configure_veeam_certs_permissions
    configure_veeam_reduced_sudo
    lockdown_ssh_after_attach
    show_lockdown_summary
}

main() {
    parse_args "$@"
    require_root
    init_logging
    validate_common_inputs
    load_os_release
    ensure_safe_workdir

    if [[ "$INTERACTIVE" == "yes" && $# -eq 0 ]]; then
        wizard_start_menu
    fi

    case "$PHASE" in
        prepare)
            prepare_flow
            ;;
        post-attach-lockdown)
            post_attach_lockdown_flow
            ;;
        *)
            die "Unsupported phase: ${PHASE}"
            ;;
    esac
}

main "$@"
