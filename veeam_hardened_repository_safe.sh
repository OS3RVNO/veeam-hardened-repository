#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2026.06.11"
FORCED_TIMEZONE="Europe/Rome"
export TZ="$FORCED_TIMEZONE"

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
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
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
PROMPT_RESULT=""
TUI_TITLE="veeam-hardened"

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
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
fi

# --------------------[ UI ]--------------------
ui() { printf "%b\n" "$*" >&2; }
ui_inline() { printf "%b" "$*" >&2; }
line() { printf "%b\n" "${C_DIM}-----------------------------------------------------------------${C_RESET}" >&2; }
tui_available() {
    [[ "$INTERACTIVE" == "yes" ]] || return 1
    [[ -t 0 && -t 1 ]] || return 1
    [[ "${TERM:-dumb}" != "dumb" ]] || return 1
    cmd_exists whiptail
}

tui_msgbox() {
    local text="$1"
    whiptail --title "$TUI_TITLE" --scrolltext --msgbox "$text" 20 86
}

tui_inputbox() {
    local prompt="$1"
    local current="$2"
    local answer

    answer="$(whiptail --title "$TUI_TITLE" --inputbox "$prompt" 14 86 "$current" 3>&1 1>&2 2>&3)" || die "Operation cancelled by the user."
    answer="$(normalize_ws "$answer")"
    [[ -n "$answer" ]] || die "The value cannot be empty."
    PROMPT_RESULT="$answer"
}

tui_yes_no() {
    local prompt="$1"
    local default="$2"
    local -a cmd=(whiptail --title "$TUI_TITLE" --yesno "$prompt" 12 86)

    [[ "$default" == "no" ]] && cmd=(whiptail --title "$TUI_TITLE" --defaultno --yesno "$prompt" 12 86)

    if "${cmd[@]}"; then
        PROMPT_RESULT="yes"
    else
        PROMPT_RESULT="no"
    fi
}

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
    ui "${C_RESET}${C_BOLD}veeam-hardened${C_RESET}"
    ui "${C_BOLD}Hardened Repository Safer Bootstrap${C_RESET}"
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
    if tui_available; then
        tui_msgbox "Press ENTER or OK to continue."
        return 0
    fi
    read -r -p "$(printf '%b' "${C_DIM}Press ENTER to continue...${C_RESET}")" || die "Input stream closed while waiting for confirmation."
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
    trap - ERR
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

validate_lvm_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]{0,126}$ ]] || return 1
    case "$1" in
        .|..|*_tmeta|*_tdata|*_cdata|*_cmeta|snapshot|pvmove*)
            return 1
            ;;
    esac
    return 0
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

canonicalize_block_device() {
    local device="$1"
    readlink -f "$device" 2>/dev/null || printf '%s\n' "$device"
}

escape_path_regex() {
    printf '%s' "$1" | sed -e 's/\./\\./g'
}

validate_whole_disk_device() {
    [[ "$(lsblk -dn -o TYPE "$1" 2>/dev/null || true)" == "disk" ]]
}

validate_repository_disk_device() {
    validate_whole_disk_device "$1" || return 1
    case "$1" in
        /dev/ram*|/dev/zram*)
            return 1
            ;;
    esac
    return 0
}

path_has_symlink_component() {
    local path="$1"
    local current="" part

    [[ "$path" == /* ]] || return 1

    IFS='/' read -r -a path_parts <<< "$path"
    current="/"
    for part in "${path_parts[@]}"; do
        [[ -n "$part" ]] || continue
        if [[ "$current" == "/" ]]; then
            current="/${part}"
        else
            current="${current}/${part}"
        fi
        [[ -L "$current" ]] && return 0
    done

    return 1
}

path_is_under_mountpoint() {
    local path="$1"
    local base="$2"
    [[ "$path" == "$base" || "$path" == "$base/"* ]]
}

normalize_dir_path() {
    local path="$1"
    [[ "$path" == "/" ]] || path="${path%/}"
    printf '%s\n' "$path"
}

path_mount_target() {
    local path="$1"
    path="$(normalize_dir_path "$path")"
    findmnt -n -o TARGET --target "$path" 2>/dev/null | awk 'NF {print; exit}' || true
}

mountpoint_in_use() {
    local path="$1"
    local target
    path="$(normalize_dir_path "$path")"
    target="$(findmnt -n -o TARGET --target "$path" 2>/dev/null | awk 'NF {print; exit}' || true)"
    [[ "$target" == "$path" ]]
}

mountpoint_source() {
    local path="$1"
    local target

    path="$(normalize_dir_path "$path")"
    target="$(findmnt -n -o TARGET --target "$path" 2>/dev/null | awk 'NF {print; exit}' || true)"
    [[ "$target" == "$path" ]] || return 1
    findmnt -n -o SOURCE --target "$path" 2>/dev/null | awk 'NF {print; exit}' || true
}

repo_lv_mounted_at_target() {
    local target="$1"
    local lv_path expected_source mounted_source

    lv_path="$(find_target_repo_lv_path || true)"
    [[ -n "$lv_path" ]] || return 1

    expected_source="$(canonicalize_block_device "$lv_path")"
    mounted_source="$(mountpoint_source "$target" 2>/dev/null || true)"
    [[ -n "$mounted_source" ]] || return 1
    mounted_source="$(canonicalize_block_device "$mounted_source")"
    [[ "$mounted_source" == "$expected_source" ]]
}

fstab_source_matches_lv() {
    local source="$1"
    local uuid="$2"
    local lv_path="$3"
    local canonical_source canonical_lv

    [[ "$source" == "UUID=${uuid}" ]] && return 0
    [[ "$source" == "$lv_path" ]] && return 0

    canonical_lv="$(canonicalize_block_device "$lv_path")"
    canonical_source="$(canonicalize_block_device "$source")"
    [[ "$canonical_source" == "$canonical_lv" ]]
}

find_existing_repo_mount_target() {
    local lv_path="$1"
    local uuid source target

    uuid="$(blkid -s UUID -o value "$lv_path" 2>/dev/null || true)"
    [[ -n "$uuid" ]] || return 1

    if repo_lv_mounted_at_target "$REPO_DIR"; then
        printf '%s\n' "$REPO_DIR"
        return 0
    fi

    if repo_lv_mounted_at_target "$MOUNT_POINT"; then
        printf '%s\n' "$MOUNT_POINT"
        return 0
    fi

    while read -r source target; do
        [[ -n "$source" && -n "$target" ]] || continue
        target="$(normalize_dir_path "$target")"
        [[ "$target" == "$REPO_DIR" || "$target" == "$MOUNT_POINT" ]] || continue
        if fstab_source_matches_lv "$source" "$uuid" "$lv_path"; then
            printf '%s\n' "$target"
            return 0
        fi
    done < <(awk '$1 !~ /^#/ && NF >= 2 {print $1, $2}' /etc/fstab 2>/dev/null || true)

    return 1
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

replace_fstab_target_entry() {
    local target_path="$1"
    local uuid="$2"
    local tmp

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN rewrite fstab entry for ${target_path}: UUID=${uuid} ${target_path} xfs ${FSTAB_OPTS} 0 0"
        return 0
    fi

    tmp="$(mktemp)"
    awk -v target="$target_path" '$2 != target {print $0}' /etc/fstab > "$tmp"
    printf 'UUID=%s %s xfs %s 0 0\n' "$uuid" "$target_path" "$FSTAB_OPTS" >> "$tmp"
    backup_file /etc/fstab
    install -o root -g root -m 0644 "$tmp" /etc/fstab
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

set_spaced_kv_in_file() {
    local key="$1"
    local value="$2"
    local file="$3"
    local tmp

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN set ${key} ${value} in ${file}"
        return 0
    fi

    tmp="$(mktemp)"
    touch "$file"
    awk -v key="$key" -v value="$value" '
        BEGIN { done = 0 }
        {
            trimmed = $0
            sub(/^[[:space:]]+/, "", trimmed)
            if (trimmed ~ "^#?[[:space:]]*" key "([[:space:]]|$)") {
                if (!done) {
                    printf "%s\t%s\n", key, value
                    done = 1
                }
                next
            }
            print
        }
        END {
            if (!done) {
                printf "%s\t%s\n", key, value
            }
        }
    ' "$file" > "$tmp"
    backup_file "$file"
    install -o root -g root -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

set_pam_module_line() {
    local file="$1"
    local module_pattern="$2"
    local replacement="$3"
    local anchor_pattern="$4"
    local tmp

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN update PAM line in ${file}: ${replacement}"
        return 0
    fi

    tmp="$(mktemp)"
    touch "$file"
    awk -v module_pattern="$module_pattern" -v replacement="$replacement" -v anchor_pattern="$anchor_pattern" '
        BEGIN { done = 0 }
        {
            if ($0 ~ module_pattern) {
                if (!done) {
                    print replacement
                    done = 1
                }
                next
            }
            if (!done && $0 ~ anchor_pattern) {
                print replacement
                done = 1
            }
            print
        }
        END {
            if (!done) {
                print replacement
            }
        }
    ' "$file" > "$tmp"
    backup_file "$file"
    install -o root -g root -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

set_line_matching_regex() {
    local regex="$1"
    local replacement="$2"
    local file="$3"
    local tmp

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN update line in ${file}: ${replacement}"
        return 0
    fi

    tmp="$(mktemp)"
    touch "$file"
    awk -v regex="$regex" -v replacement="$replacement" '
        BEGIN { done = 0 }
        {
            if ($0 ~ regex) {
                if (!done) {
                    print replacement
                    done = 1
                }
                next
            }
            print
        }
        END {
            if (!done) {
                print replacement
            }
        }
    ' "$file" > "$tmp"
    backup_file "$file"
    install -o root -g root -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

remove_lines_matching_regex() {
    local regex="$1"
    local file="$2"
    local tmp

    [[ -e "$file" ]] || return 0

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN remove lines from ${file} matching ${regex}"
        return 0
    fi

    tmp="$(mktemp)"
    awk -v regex="$regex" '$0 !~ regex { print }' "$file" > "$tmp"
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
    local password=""
    local needed chunk

    while (( ${#password} < 24 )); do
        needed=$((24 - ${#password}))
        chunk="$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%_=+.-' < /dev/urandom | head -c "$needed" || true)"
        [[ -n "$chunk" ]] || die "Unable to generate a random password."
        password+="$chunk"
    done

    printf '%s' "$password"
}

veeam_agent_for_linux_installed() {
    dpkg-query -W -f='${Status}\n' veeam 2>/dev/null | grep -Fxq 'install ok installed' && return 0
    cmd_exists systemctl && systemctl list-unit-files veeamservice.service 2>/dev/null | grep -Fq 'veeamservice.service' && return 0
    return 1
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

ensure_timezone_europe_rome() {
    local zoneinfo="/usr/share/zoneinfo/${FORCED_TIMEZONE}"
    local current_timezone=""

    [[ -e "$zoneinfo" ]] || die "Timezone data not found for ${FORCED_TIMEZONE}."

    if cmd_exists timedatectl; then
        current_timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
        if [[ "$current_timezone" == "$FORCED_TIMEZONE" ]]; then
            return 0
        fi

        if timedatectl set-timezone "$FORCED_TIMEZONE" >/dev/null 2>&1; then
            return 0
        fi

        warn "timedatectl could not set timezone to ${FORCED_TIMEZONE}. Falling back to /etc/localtime."
    fi

    ln -snf "$zoneinfo" /etc/localtime
    printf '%s\n' "$FORCED_TIMEZONE" > /etc/timezone
}

ubuntu_supported() {
    [[ "$OS_ID" == "ubuntu" && ( "$OS_VERSION_ID" == "22.04" || "$OS_VERSION_ID" == "24.04" ) ]]
}

detect_partition_name() {
    if [[ "$BACKUP_DISK" =~ [0-9]$ ]]; then
        PARTITION_NAME="${BACKUP_DISK}p1"
    else
        PARTITION_NAME="${BACKUP_DISK}1"
    fi
}

get_system_disks() {
    local root_source
    root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ -n "$root_source" ]] || return 1
    lsblk -nrpo NAME,TYPE "$root_source" 2>/dev/null | awk '$2 == "disk" {print $1}' | sort -u
}

get_system_disk() {
    get_system_disks 2>/dev/null | head -n 1
}

list_candidate_backup_disks() {
    local name type size model
    local -a system_disks=()

    while read -r name; do
        [[ -n "$name" ]] || continue
        system_disks+=("$name")
    done < <(get_system_disks || true)

    while read -r name type size model; do
        [[ "$type" == "disk" ]] || continue
        [[ -n "$name" ]] || continue
        [[ "$name" == ram* || "$name" == zram* ]] && continue
        if printf '%s\n' "${system_disks[@]}" | grep -Fxq "/dev/${name}"; then
            continue
        fi
        printf '/dev/%s|%s|%s\n' "$name" "$size" "${model:-unknown}"
    done < <(lsblk -dn -e 2,11 -o NAME,TYPE,SIZE,MODEL 2>/dev/null)
}

show_candidate_backup_disks() {
    local disk size model idx=1
    ui "${C_BOLD}Candidate repository disks:${C_RESET}"
    while IFS='|' read -r disk size model; do
        ui "  ${idx}) ${disk} - ${size} - ${model}"
        ((idx += 1))
    done < <(list_candidate_backup_disks)
}

maybe_autodetect_backup_disk() {
    local candidate_count=0
    local last_candidate=""
    local disk size model

    if [[ "$BACKUP_DISK" != "auto" ]]; then
        BACKUP_DISK="$(canonicalize_block_device "$BACKUP_DISK")"
        validate_block_device "$BACKUP_DISK" || die "The specified disk is not a valid block device: ${BACKUP_DISK}"
        validate_repository_disk_device "$BACKUP_DISK" || die "The specified --disk must be a supported whole disk device, not a partition, mapper node, or ram disk: ${BACKUP_DISK}"
        return 0
    fi

    while IFS='|' read -r disk size model; do
        [[ -n "$disk" ]] || continue
        last_candidate="$disk"
        ((candidate_count += 1))
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

maybe_load_prepare_state() {
    local current_backup_disk current_mount current_repo current_vg current_lv
    local current_user current_group current_ssh_nets current_veeam_nets

    [[ "$PHASE" == "post-attach-lockdown" ]] || return 0
    [[ -r "$TIMESTAMP_FILE" ]] || return 0

    current_backup_disk="$BACKUP_DISK"
    current_mount="$MOUNT_POINT"
    current_repo="$REPO_DIR"
    current_vg="$VG_NAME"
    current_lv="$LV_NAME"
    current_user="$VEEAM_USER"
    current_group="$VEEAM_GROUP"
    current_ssh_nets="$SSH_ALLOWED_NETS"
    current_veeam_nets="$VEEAM_ALLOWED_NETS"

    # shellcheck disable=SC1090
    . "$TIMESTAMP_FILE"

    [[ "$current_backup_disk" != "$DEFAULT_BACKUP_DISK" ]] && BACKUP_DISK="$current_backup_disk"
    [[ "$current_mount" != "$DEFAULT_MOUNT_POINT" ]] && MOUNT_POINT="$current_mount"
    [[ "$current_repo" != "$DEFAULT_REPO_DIR" ]] && REPO_DIR="$current_repo"
    [[ "$current_vg" != "$DEFAULT_VG_NAME" ]] && VG_NAME="$current_vg"
    [[ "$current_lv" != "$DEFAULT_LV_NAME" ]] && LV_NAME="$current_lv"
    [[ "$current_user" != "$DEFAULT_VEEAM_USER" ]] && VEEAM_USER="$current_user"
    [[ "$current_group" != "$DEFAULT_VEEAM_GROUP" ]] && VEEAM_GROUP="$current_group"
    [[ "$current_ssh_nets" != "$DEFAULT_SSH_ALLOWED_NETS" ]] && SSH_ALLOWED_NETS="$current_ssh_nets"
    [[ "$current_veeam_nets" != "$DEFAULT_VEEAM_ALLOWED_NETS" ]] && VEEAM_ALLOWED_NETS="$current_veeam_nets"
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

vg_is_fully_on_target_disk() {
    local vg_name="$1"
    local count=0
    local pv_name

    while read -r pv_name; do
        pv_name="$(normalize_ws "$pv_name")"
        [[ -n "$pv_name" ]] || continue
        ((count += 1))
        device_belongs_to_disk "$BACKUP_DISK" "$pv_name" || return 1
    done < <(get_pvs_for_vg "$vg_name")

    (( count > 0 ))
}

find_target_repo_lv_path() {
    local lv_path
    lv_path="$(find_repo_lv_path || true)"
    [[ -n "$lv_path" ]] || return 1
    vg_is_fully_on_target_disk "$VG_NAME" || return 1
    printf '%s\n' "$lv_path"
}

disk_has_partitions() {
    lsblk -nrpo NAME "$1" 2>/dev/null | tail -n +2 | grep -q .
}

pv_assigned_vg() {
    local pv_name="$1"
    pvs --noheadings -o vg_name "$pv_name" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -n 1
}

expected_repo_pv_target() {
    if [[ "$USE_PARTITION" == "yes" ]]; then
        detect_partition_name
        printf '%s\n' "$PARTITION_NAME"
    else
        printf '%s\n' "$BACKUP_DISK"
    fi
}

repo_storage_repairable() {
    local lv_path pv_target pv_vg

    lv_path="$(find_target_repo_lv_path || true)"
    [[ -n "$lv_path" ]] && return 0

    if vgs "$VG_NAME" >/dev/null 2>&1 && vg_is_fully_on_target_disk "$VG_NAME"; then
        return 0
    fi

    pv_target="$(expected_repo_pv_target)"
    if [[ "$USE_PARTITION" == "yes" && -b "$pv_target" ]]; then
        if pvs "$pv_target" >/dev/null 2>&1 || ! device_has_existing_signatures "$pv_target"; then
            return 0
        fi
    fi

    if pvs "$pv_target" >/dev/null 2>&1; then
        pv_vg="$(pv_assigned_vg "$pv_target")"
        [[ -z "$pv_vg" || "$pv_vg" == "$VG_NAME" ]] && return 0
    fi

    return 1
}

repo_lv_is_xfs() {
    local lv_path
    lv_path="$(find_target_repo_lv_path || true)"
    [[ -n "$lv_path" ]] || return 1
    blkid "$lv_path" 2>/dev/null | grep -q 'TYPE="xfs"'
}

repo_storage_present() {
    local lv_path
    lv_path="$(find_target_repo_lv_path || true)"
    [[ -n "$lv_path" ]] || return 1
    repo_lv_is_xfs
}

repo_path_ready() {
    [[ -n "$(find_target_repo_lv_path || true)" ]] || return 1
    repo_lv_is_xfs || return 1
    [[ -d "$MOUNT_POINT" ]] || return 1
    if repo_lv_mounted_at_target "$MOUNT_POINT"; then
        [[ -d "$REPO_DIR" ]] || return 1
        return 0
    fi
    repo_lv_mounted_at_target "$REPO_DIR"
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
        PROMPT_RESULT="$default"
        return 0
    }

    if tui_available; then
        tui_yes_no "$prompt" "$default"
        return 0
    fi

    while true; do
        if [[ "$default" == "yes" ]]; then
            ui_inline "${C_BOLD}${prompt}${C_RESET} [Y/n]: "
            read -r answer || die "Input stream closed while waiting for yes/no input."
            answer="${answer:-yes}"
        else
            ui_inline "${C_BOLD}${prompt}${C_RESET} [y/N]: "
            read -r answer || die "Input stream closed while waiting for yes/no input."
            answer="${answer:-no}"
        fi

        if is_yes "$answer"; then
            PROMPT_RESULT="yes"
            return 0
        fi
        if is_no "$answer"; then
            PROMPT_RESULT="no"
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
        PROMPT_RESULT="$current"
        return 0
    }

    if tui_available; then
        tui_inputbox "$prompt" "$current"
        return 0
    fi

    while true; do
        ui_inline "${C_BOLD}${prompt}${C_RESET} [${current}]: "
        read -r answer || die "Input stream closed while waiting for a required value."
        answer="${answer:-$current}"
        answer="$(normalize_ws "$answer")"
        [[ -n "$answer" ]] || {
            warn "The value cannot be empty."
            continue
        }
        PROMPT_RESULT="$answer"
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
      user privileges, protects Veeam certificate directories, applies
      stricter STIG-style hardening, and can block SSH.

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
  - owns the repository directory, with the matching primary group and 0700 permissions
  - uses a repository path without symbolic links
  Veeam infrastructure networks that need direct repository access must be allowed on ports 6160, 6162 and 2500:3300.
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
    [[ "$VEEAM_USER" != "root" ]] || die "The Veeam onboarding account must be a non-root user."
    validate_group_name "$VEEAM_GROUP" || die "Invalid group name: ${VEEAM_GROUP}"
    [[ "$VEEAM_GROUP" == "$VEEAM_USER" ]] || die "For a Veeam hardened repository, --veeam-group must match --veeam-user."

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
    MOUNT_POINT="$(normalize_dir_path "$MOUNT_POINT")"
    REPO_DIR="$(normalize_dir_path "$REPO_DIR")"

    validate_block_device "$BACKUP_DISK" || die "Invalid block device: ${BACKUP_DISK}"
    validate_repository_disk_device "$BACKUP_DISK" || die "The selected --disk must be a supported whole disk device: ${BACKUP_DISK}"
    validate_mount_path "$MOUNT_POINT" || die "Invalid mount point: ${MOUNT_POINT}"
    validate_mount_path "$REPO_DIR" || die "Invalid repository directory: ${REPO_DIR}"
    validate_lv_size "$LV_SIZE" || die "Invalid LV_SIZE: ${LV_SIZE}"
    validate_lvm_name "$VG_NAME" || die "Invalid LVM volume group name: ${VG_NAME}"
    validate_lvm_name "$LV_NAME" || die "Invalid LVM logical volume name: ${LV_NAME}"
    [[ "$VG_NAME" != "$LV_NAME" ]] || die "--vg and --lv must be different names."
    [[ "$MOUNT_POINT" != "/" ]] || die "Refusing to use / as repository mount point."
    [[ "$REPO_DIR" != "$MOUNT_POINT" ]] || die "REPO_DIR must be a dedicated subdirectory under MOUNT_POINT, not the mount point itself."
    path_is_under_mountpoint "$REPO_DIR" "$MOUNT_POINT" || die "REPO_DIR must be under MOUNT_POINT."
    path_has_symlink_component "$MOUNT_POINT" && die "Veeam does not support symbolic links in the path to the hardened repository mount point: ${MOUNT_POINT}"
    path_has_symlink_component "$REPO_DIR" && die "Veeam does not support symbolic links in the path to the hardened repository directory: ${REPO_DIR}"

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
    local -a menu_items=()

    while IFS='|' read -r disk size model; do
        [[ -n "$disk" ]] || continue
        disks+=("$disk")
        labels+=("${idx}) ${disk} - ${size} - ${model}")
        menu_items+=("$disk" "${size} ${model}")
        ((idx += 1))
    done < <(list_candidate_backup_disks)

    (( ${#disks[@]} > 0 )) || die "No candidate disk is available."

    if tui_available; then
        choice="$(whiptail --title "$TUI_TITLE" --menu "Select the dedicated repository disk" 20 90 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)" || die "Operation cancelled by the user."
        BACKUP_DISK="$choice"
        ok "Selected disk: ${BACKUP_DISK}"
        return 0
    fi

    ui "${C_BOLD}Select the dedicated repository disk:${C_RESET}"
    for label in "${labels[@]}"; do
        ui "  ${label}"
    done

    while true; do
        ui_inline "Choice [1-${#disks[@]}]: "
        read -r choice || die "Input stream closed while waiting for disk selection."

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
    if tui_available; then
        local choice
        choice="$(whiptail --title "$TUI_TITLE" --menu "Select an action" 18 86 8 \
            "1" "Start prepare mode" \
            "2" "Start post-attach-lockdown mode" \
            "3" "Show quick help" \
            "4" "Show extended help" \
            "5" "Exit" \
            3>&1 1>&2 2>&3)" || exit 0
        case "$choice" in
            1) PHASE="prepare"; return 0 ;;
            2) PHASE="post-attach-lockdown"; return 0 ;;
            3) show_help; exit 0 ;;
            4) show_help_full; exit 0 ;;
            5) exit 0 ;;
        esac
    fi

    cat <<EOF
1) Start prepare mode
2) Start post-attach-lockdown mode
3) Show quick help
4) Show extended help
5) Exit
EOF
    local choice
    while true; do
        read -r -p "Choice [1-5]: " choice || die "Input stream closed while waiting for menu selection."
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
    ask_required_value "Allowed SSH networks (comma-separated CIDRs)" "${SSH_ALLOWED_NETS:-192.168.10.0/24}"
    SSH_ALLOWED_NETS="$PROMPT_RESULT"
    ask_required_value "Allowed Veeam infrastructure networks (backup server, proxy, mount/gateway; ports 6160, 6162, 2500:3300)" "${VEEAM_ALLOWED_NETS:-$SSH_ALLOWED_NETS}"
    VEEAM_ALLOWED_NETS="$PROMPT_RESULT"
    ask_required_value "Mount point" "$MOUNT_POINT"
    MOUNT_POINT="$PROMPT_RESULT"
    autofill_repo_dir_from_mount
    ask_required_value "Repository directory" "$REPO_DIR"
    REPO_DIR="$PROMPT_RESULT"

    if tui_available; then
        tui_msgbox "Selected repository disk: ${BACKUP_DISK}

During the prepare phase, the user ${VEEAM_USER} keeps full sudo to avoid issues during the first Veeam onboarding.

The actual lock-down is applied only in the next phase."
    else
        ui ""
        ui "${C_BOLD}Operational note:${C_RESET}"
        ui "  Selected repository disk: ${BACKUP_DISK}"
        ui "  During the prepare phase, the user ${VEEAM_USER} keeps full sudo"
        ui "  to avoid issues during the first Veeam onboarding."
        ui "  The actual lock-down is applied only in the next phase."
        pause_enter
    fi
}

collect_grub_password_hash() {
    [[ "$SET_GRUB_PASSWORD" == "yes" ]] || return 0
    [[ "$INTERACTIVE" == "yes" ]] || {
        warn "GRUB password in non-interactive mode: provide a PBKDF2 hash by setting GRUB_PBKDF2_HASH in the script if you want to automate it."
        SET_GRUB_PASSWORD="no"
        return 0
    }

    section "W2" "GRUB password"
    if tui_available; then
        GRUB_PBKDF2_HASH="$(whiptail --title "$TUI_TITLE" --inputbox "Enter a grub.pbkdf2 hash already generated with grub-mkpasswd-pbkdf2. Leave blank to skip." 14 86 "$GRUB_PBKDF2_HASH" 3>&1 1>&2 2>&3)" || die "Operation cancelled by the user."
    else
        info "Enter a grub.pbkdf2 hash already generated with grub-mkpasswd-pbkdf2."
        read -r -p "grub.pbkdf2 hash (leave blank to skip): " GRUB_PBKDF2_HASH || die "Input stream closed while waiting for the GRUB hash."
    fi
    if [[ -z "$GRUB_PBKDF2_HASH" ]]; then
        warn "No hash provided. GRUB protection disabled."
        SET_GRUB_PASSWORD="no"
    fi
}

# --------------------[ Prechecks ]--------------------
check_runtime_not_on_target_mount() {
    local target_mount="$1"
    local repo_target="${2:-}"
    local pwd_mount script_mount log_mount

    pwd_mount="$(path_mount_target "$PWD")"
    script_mount="$(path_mount_target "$SCRIPT_PATH")"
    log_mount="$(path_mount_target "$LOG_DIR")"

    if [[ -n "$target_mount" && "$pwd_mount" == "$target_mount" ]] || [[ -n "$repo_target" && "$pwd_mount" == "$repo_target" ]]; then
        warn "The current working directory is on the target mount. Switching to /root."
        ensure_safe_workdir
    fi

    if [[ -n "$target_mount" && "$script_mount" == "$target_mount" ]] || [[ -n "$repo_target" && "$script_mount" == "$repo_target" ]]; then
        die "The script appears to be running from the target mount. Copy it to /root or /tmp and run it again."
    fi

    if [[ -n "$target_mount" && "$log_mount" == "$target_mount" ]] || [[ -n "$repo_target" && "$log_mount" == "$repo_target" ]]; then
        die "The log directory is on the target mount. Stopping to avoid I/O on the disk being initialized."
    fi
}

check_disk_is_not_system_disk() {
    local system_disk
    local found="no"

    while read -r system_disk; do
        [[ -n "$system_disk" ]] || continue
        found="yes"
        [[ "$BACKUP_DISK" != "$system_disk" ]] || die "The selected disk (${BACKUP_DISK}) appears to be a backing disk of the running system."
    done < <(get_system_disks || true)

    [[ "$found" == "yes" ]] || {
        warn "Unable to determine the root backing disk."
        return 0
    }
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

    veeam_agent_for_linux_installed && die "Veeam Agent for Linux appears to be installed on this server. Veeam documentation does not support using it on backup infrastructure components, including hardened repositories."

    ensure_safe_workdir
    check_runtime_not_on_target_mount "$MOUNT_POINT" "$REPO_DIR"
    check_disk_is_not_system_disk

    info "Current target disk layout:"
    lsblk -f "$BACKUP_DISK" | tee -a "$MAIN_LOG" >/dev/null
    lsblk -f "$BACKUP_DISK" >&2 || true

    if device_has_existing_signatures "$BACKUP_DISK"; then
        if repo_storage_present; then
            ok "Disk signatures are present, but they appear to belong to the existing repository storage."
        elif repo_storage_repairable; then
            warn "Disk signatures are present, but they match a repairable partial repository layout. The script will reconcile the storage state."
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
    elif mountpoint_in_use "$REPO_DIR"; then
        warn "The repository directory ${REPO_DIR} is already mounted."
    else
        ok "Neither ${MOUNT_POINT} nor ${REPO_DIR} is currently mounted."
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
    require_cmd systemctl

    getent passwd "$VEEAM_USER" >/dev/null 2>&1 || die "The user ${VEEAM_USER} does not exist."
    info "Target user: ${VEEAM_USER}"

    veeam_agent_for_linux_installed && die "Veeam Agent for Linux appears to be installed on this server. Veeam documentation does not support using it on backup infrastructure components, including hardened repositories."

    if alternate_admin_account_exists; then
        ok "An alternate admin account in the sudo group is present."
    elif root_password_is_locked; then
        die "No alternate admin account was found in the sudo group, and the root password appears locked. Post-attach lockdown would remove the last practical administrative path."
    else
        warn "No alternate admin account was found in the sudo group. The root password appears set, so only local console recovery remains after lockdown."
    fi

    if [[ ! -d /opt/veeam/transport/certs ]]; then
        warn "The directory /opt/veeam/transport/certs does not exist yet."
        warn "This usually means the first Data Mover deployment has not happened yet."
    else
        ok "Veeam certificate directory detected."
    fi

    if cmd_exists sshd; then
        ok "OpenSSH server tooling detected."
    elif [[ "$DISABLE_SSHD_AFTER_ATTACH" == "yes" ]]; then
        info "OpenSSH server tooling is not present. This is acceptable because SSHD is configured to remain disabled after attach."
    else
        warn "OpenSSH server tooling is not present. The post-attach phase will install openssh-server so the SSH configuration can be validated and aligned."
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
        whiptail
        libpam-pwquality
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

install_lockdown_packages() {
    section "1" "Lockdown packages"

    local packages=(
        auditd
        audispd-plugins
        aide
        aide-common
        openssh-server
    )
    local missing=()
    local pkg

    for pkg in "${packages[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    if (( ${#missing[@]} == 0 )); then
        ok "Required lockdown packages are already installed."
        return 0
    fi

    run_or_die "APT update" apt update
    run_or_die "Install lockdown packages" apt install -y "${missing[@]}"
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
    while IFS='|' read -r pv vg; do
        pv="$(normalize_ws "$pv")"
        vg="$(normalize_ws "$vg")"
        [[ -n "${pv:-}" && -n "${vg:-}" ]] || continue
        if device_belongs_to_disk "$disk" "$pv"; then
            printf '%s\n' "$vg"
        fi
    done < <(pvs --noheadings --separator '|' -o pv_name,vg_name 2>/dev/null | sed 's/^[[:space:]]*//')
}

get_pvs_for_vg() {
    local wanted_vg="$1"
    local pv vg
    while IFS='|' read -r pv vg; do
        pv="$(normalize_ws "$pv")"
        vg="$(normalize_ws "$vg")"
        [[ -n "$pv" && -n "$vg" ]] || continue
        [[ "$vg" == "$wanted_vg" ]] || continue
        printf '%s\n' "$pv"
    done < <(pvs --noheadings --separator '|' -o pv_name,vg_name 2>/dev/null | sed 's/^[[:space:]]*//')
}

get_lvs_for_vg() {
    local wanted_vg="$1"
    local lv vg
    while IFS='|' read -r lv vg; do
        lv="$(normalize_ws "$lv")"
        vg="$(normalize_ws "$vg")"
        [[ -n "$lv" && -n "$vg" ]] || continue
        [[ "$vg" == "$wanted_vg" ]] || continue
        printf '%s\n' "$lv"
    done < <(lvs --noheadings --separator '|' -o lv_name,vg_name 2>/dev/null | sed 's/^[[:space:]]*//')
}

wipe_target_disk_safely() {
    section "2" "Safe target disk cleanup"

    local disk="$1"
    local part mountp dev vg lv pv other_pv count disk_size seek
    local -a processed_vgs=()

    ensure_safe_workdir
    check_runtime_not_on_target_mount "$MOUNT_POINT" "$REPO_DIR"
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
            ((count += 1))
            device_belongs_to_disk "$disk" "$other_pv" || die "VG ${vg} also uses PV ${other_pv}, which is outside the target disk. Stopping for safety."
        done < <(get_pvs_for_vg "$vg")

        (( count > 0 )) || continue

        while read -r lv; do
            lv="$(normalize_ws "$lv")"
            [[ -n "$lv" ]] || continue
            run_or_die "Remove LV ${vg}/${lv}" lvremove -f "/dev/${vg}/${lv}"
        done < <(get_lvs_for_vg "$vg")

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
    local pv_existing_vg=""
    local -a lvcreate_args

    if [[ -e "$lv_path" ]]; then
        vg_is_fully_on_target_disk "$VG_NAME" || die "LV ${lv_path} already exists, but it does not belong to the selected target disk ${BACKUP_DISK}."
        if repo_lv_is_xfs; then
            ok "LV ${lv_path} already exists."
            return 0
        fi
        if blkid "$lv_path" 2>/dev/null | grep -q 'TYPE='; then
            [[ "$FORCE_WIPE" == "yes" ]] || die "LV ${lv_path} exists with a non-XFS filesystem. Use --force-wipe yes if you want the script to rebuild the selected disk."
            warn "LV ${lv_path} exists with a non-XFS filesystem. Rebuilding the selected disk because FORCE_WIPE=yes."
            wipe_target_disk_safely "$BACKUP_DISK"
        else
            ok "LV ${lv_path} already exists without a filesystem. The script will reuse it and continue with XFS creation."
            return 0
        fi
    fi

    if [[ "$FORCE_WIPE" == "yes" ]] && ! repo_storage_repairable; then
        wipe_target_disk_safely "$BACKUP_DISK"
    fi

    if vgs "$VG_NAME" >/dev/null 2>&1; then
        vg_is_fully_on_target_disk "$VG_NAME" || die "VG ${VG_NAME} already exists, but it does not belong exclusively to the selected target disk ${BACKUP_DISK}."
        ok "VG ${VG_NAME} already exists on the selected target disk."
    else
        pv_target="$(expected_repo_pv_target)"

        if [[ "$USE_PARTITION" == "yes" ]]; then
            if [[ -b "$pv_target" ]]; then
                ok "Repository partition ${pv_target} already exists."
                if ! pvs "$pv_target" >/dev/null 2>&1 && device_has_existing_signatures "$pv_target"; then
                    die "Partition ${pv_target} already contains signatures that are not an initialized repository PV. Use --force-wipe yes if you want to rebuild the selected disk."
                fi
            else
                disk_has_partitions "$BACKUP_DISK" && die "The target disk already contains partitions, but the expected repository partition ${pv_target} is missing. Use --force-wipe yes to rebuild the disk cleanly."
                run_or_die "Create GPT label" parted -s "$BACKUP_DISK" mklabel gpt
                run_or_die "Create LVM partition" parted -s -a optimal "$BACKUP_DISK" mkpart primary 1MiB 100%
                run_or_die "Set LVM flag" parted -s "$BACKUP_DISK" set 1 lvm on
                run_or_die "Reload partition table" partprobe "$BACKUP_DISK"
                run_or_die "Wait udev settle" udevadm settle
                [[ -b "$pv_target" ]] || die "Expected partition ${pv_target} did not appear."
            fi
        fi

        if ! pvs "$pv_target" >/dev/null 2>&1; then
            run_or_die "Create PV ${pv_target}" pvcreate -ff -y "$pv_target"
        else
            ok "PV ${pv_target} already exists."
        fi

        pv_existing_vg="$(pv_assigned_vg "$pv_target")"
        if [[ -n "$pv_existing_vg" && "$pv_existing_vg" != "$VG_NAME" ]]; then
            die "PV ${pv_target} already belongs to VG ${pv_existing_vg}, not to the expected VG ${VG_NAME}. Use --force-wipe yes if you want to rebuild the selected disk."
        fi

        run_or_die "Create VG ${VG_NAME}" vgcreate "$VG_NAME" "$pv_target"
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
    local target_path="$2"
    local uuid existing source target current_opts
    uuid="$(blkid -s UUID -o value "$lv_path")"
    [[ -n "$uuid" ]] || die "Unable to read the UUID of ${lv_path}."

    target_path="$(normalize_dir_path "$target_path")"
    existing="$(awk -v target="$target_path" '$1 !~ /^#/ && $2 == target {print $0}' /etc/fstab 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        source="$(awk '{print $1}' <<< "$existing")"
        current_opts="$(awk '{print $4}' <<< "$existing")"
        if fstab_source_matches_lv "$source" "$uuid" "$lv_path"; then
            if [[ "$current_opts" == "$FSTAB_OPTS" ]]; then
                ok "fstab entry already present for ${target_path}."
            else
                warn "fstab entry for ${target_path} exists but uses different mount options. Rewriting it to ${FSTAB_OPTS}."
                replace_fstab_target_entry "$target_path" "$uuid"
            fi
            return 0
        fi
        warn "fstab entry for ${target_path} exists but does not point to the expected LV. Rewriting it."
        replace_fstab_target_entry "$target_path" "$uuid"
        return 0
    fi

    while read -r source target; do
        [[ -n "$source" && -n "$target" ]] || continue
        target="$(normalize_dir_path "$target")"
        if fstab_source_matches_lv "$source" "$uuid" "$lv_path"; then
            if [[ "$target" == "$MOUNT_POINT" || "$target" == "$REPO_DIR" ]]; then
                ok "fstab entry already present for ${target}."
                return 0
            fi
            die "The repository LV is already present in /etc/fstab with an unsupported target path: ${target}"
        fi
    done < <(awk '$1 !~ /^#/ && NF >= 2 {print $1, $2}' /etc/fstab 2>/dev/null || true)

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN add fstab: UUID=${uuid} ${target_path} xfs ${FSTAB_OPTS} 0 0"
        return 0
    fi

    backup_file /etc/fstab
    printf 'UUID=%s %s xfs %s 0 0\n' "$uuid" "$target_path" "$FSTAB_OPTS" >> /etc/fstab
}

mount_repo() {
    section "5" "Mount repository"

    local lv_path="/dev/${VG_NAME}/${LV_NAME}"
    local expected_source mounted_source mount_target
    run_or_die "Create mount point ${MOUNT_POINT}" mkdir -p "$MOUNT_POINT"
    run_or_die "Create repository dir ${REPO_DIR}" mkdir -p "$REPO_DIR"

    expected_source="$(canonicalize_block_device "$lv_path")"
    mount_target="$(find_existing_repo_mount_target "$lv_path" || true)"
    mount_target="${mount_target:-$MOUNT_POINT}"

    if [[ "$mount_target" == "$REPO_DIR" ]]; then
        info "Existing repository layout detected: the LV will be mounted directly on ${REPO_DIR}."
    fi

    if mountpoint_in_use "$mount_target"; then
        mounted_source="$(mountpoint_source "$mount_target" 2>/dev/null || true)"
        mounted_source="$(canonicalize_block_device "$mounted_source")"
        [[ "$mounted_source" == "$expected_source" ]] || die "Target ${mount_target} is already mounted from ${mounted_source}, not from ${lv_path}."
        ok "${mount_target} is already mounted from the expected LV."
    fi

    ensure_fstab_entry "$lv_path" "$mount_target"

    if ! mountpoint_in_use "$mount_target"; then
        run_or_die "Mount ${mount_target}" mount "$mount_target"
    fi

    run_or_die "Verify mount ${mount_target}" findmnt "$mount_target"
    run_or_die "Verify XFS ${mount_target}" xfs_info "$mount_target"
}

# --------------------[ Account ]--------------------
user_password_status() {
    passwd -S "$1" 2>/dev/null | awk '{print $2}' || true
}

has_interactive_login_shell() {
    local user="$1"
    local shell_path

    shell_path="$(getent passwd "$user" | awk -F: '{print $7}' || true)"
    [[ -n "$shell_path" ]] || return 1
    case "$shell_path" in
        */false|*/nologin)
            return 1
            ;;
    esac
    return 0
}

alternate_admin_account_exists() {
    local members_csv member

    members_csv="$(getent group sudo | awk -F: '{print $4}' || true)"
    [[ -n "$members_csv" ]] || return 1

    IFS=',' read -r -a sudo_members <<< "$members_csv"
    for member in "${sudo_members[@]}"; do
        member="$(normalize_ws "$member")"
        [[ -n "$member" ]] || continue
        [[ "$member" == "$VEEAM_USER" ]] && continue
        has_interactive_login_shell "$member" || continue
        return 0
    done

    return 1
}

user_has_authorized_keys() {
    local user="$1"
    local home_dir

    home_dir="$(getent passwd "$user" | awk -F: '{print $6}' || true)"
    [[ -n "$home_dir" ]] || return 1
    [[ -s "${home_dir}/.ssh/authorized_keys" ]]
}

alternate_admin_key_login_exists() {
    local members_csv member

    members_csv="$(getent group sudo | awk -F: '{print $4}' || true)"
    [[ -n "$members_csv" ]] || return 1

    IFS=',' read -r -a sudo_members <<< "$members_csv"
    for member in "${sudo_members[@]}"; do
        member="$(normalize_ws "$member")"
        [[ -n "$member" ]] || continue
        [[ "$member" == "$VEEAM_USER" ]] && continue
        has_interactive_login_shell "$member" || continue
        user_has_authorized_keys "$member" || continue
        return 0
    done

    return 1
}

root_password_is_locked() {
    case "$(user_password_status root)" in
        L|LK|NP)
            return 0
            ;;
    esac
    return 1
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
    else
        ok "User ${VEEAM_USER} already exists."
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

    run_or_die "Align home and shell for ${VEEAM_USER}" usermod -d "/home/${VEEAM_USER}" -m -s /bin/bash "$VEEAM_USER"
    run_or_die "Set primary group of ${VEEAM_USER} to ${VEEAM_GROUP}" usermod -g "$VEEAM_GROUP" "$VEEAM_USER"
    run_or_die "Add ${VEEAM_USER} to the sudo group for the first attach" usermod -aG sudo "$VEEAM_USER"
    run_or_die "Ensure home directory exists for ${VEEAM_USER}" install -d -m 0750 -o "$VEEAM_USER" -g "$VEEAM_GROUP" "/home/${VEEAM_USER}"

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

configure_account_policy_prepare() {
    section "8" "Account and session policy"

    set_spaced_kv_in_file "PASS_MIN_DAYS" "1" /etc/login.defs
    set_spaced_kv_in_file "PASS_MAX_DAYS" "60" /etc/login.defs
    set_spaced_kv_in_file "PASS_WARN_AGE" "7" /etc/login.defs
    set_spaced_kv_in_file "UMASK" "077" /etc/login.defs

    write_file "/etc/profile.d/70-veeam-shell-timeout.sh" "0644" "root" "root" <<'EOF'
case $- in
    *i*)
        TMOUT=600
        readonly TMOUT
        export TMOUT
        ;;
esac
EOF
}

configure_password_quality_prepare() {
    section "9" "Password quality"

    local file="/etc/security/pwquality.conf"

    set_kv_in_file "minlen" "15" "$file"
    set_kv_in_file "minclass" "4" "$file"
    set_kv_in_file "difok" "8" "$file"
    set_kv_in_file "dcredit" "-1" "$file"
    set_kv_in_file "ucredit" "-1" "$file"
    set_kv_in_file "lcredit" "-1" "$file"
    set_kv_in_file "ocredit" "-1" "$file"
    set_kv_in_file "maxrepeat" "3" "$file"
    set_kv_in_file "dictcheck" "1" "$file"
    set_kv_in_file "enforcing" "1" "$file"

    set_pam_module_line \
        "/etc/pam.d/common-password" \
        '^[[:space:]]*password[[:space:]].*pam_pwquality[.]so([[:space:]]|$)' \
        'password\trequisite\t\t\tpam_pwquality.so retry=3' \
        '^[[:space:]]*password[[:space:]]*[[]success=1[[:space:]]+default=ignore[]][[:space:]]*pam_unix[.]so([[:space:]]|$)'
}

configure_time_sync_prepare() {
    section "10" "Time synchronization"

    if ! cmd_exists timedatectl; then
        warn "timedatectl is not available. Skipping time synchronization enforcement."
        return 0
    fi

    run "Enable NTP synchronization" timedatectl set-ntp true || warn "Unable to enable NTP synchronization automatically. Verify your chrony or timesyncd configuration."
}

configure_banners() {
    section "11" "Legal banners"

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
    section "12" "Kernel hardening"

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
    if [[ ! -e /etc/ssh/sshd_config ]]; then
        if [[ "$DRY_RUN" == "yes" ]]; then
            info "DRY-RUN create /etc/ssh/sshd_config with Include directive"
            return 0
        fi
        write_file "/etc/ssh/sshd_config" "0600" "root" "root" <<EOF
${include_line}
EOF
        return 0
    fi

    grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' /etc/ssh/sshd_config && return 0

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
    section "13" "SSH configuration for first attach"

    local password_auth="yes"
    [[ "$ALLOW_PASSWORD_AUTH" == "yes" ]] || password_auth="no"

    ensure_sshd_include_dropins
    install -d -m 0755 /etc/ssh/sshd_config.d

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN remove post-attach deny rule for ${VEEAM_USER} if present"
    else
        rm -f /etc/ssh/sshd_config.d/99-veeamrepo-deny.conf
    fi

    write_file "/etc/ssh/sshd_config.d/90-veeam-hardening.conf" "0644" "root" "root" <<EOF
PermitRootLogin no
UsePAM yes
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 4
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
MACs hmac-sha2-512,hmac-sha2-256
Banner /etc/issue.net
EOF

    run_or_die "Validate SSH configuration" sshd -t
    run_or_die "Enable SSH service" systemctl enable ssh
    run_or_die "Restart SSH service" systemctl restart ssh
}

configure_sudo_logging() {
    section "14" "Sudo logging"

    write_file "/etc/sudoers.d/01-veeam-logging" "0440" "root" "root" <<'EOF'
Defaults logfile=/var/log/sudo.log
Defaults log_input,log_output
Defaults use_pty
Defaults env_reset,timestamp_timeout=15
EOF

    run_or_die "Validate sudoers logging" visudo -c -f /etc/sudoers.d/01-veeam-logging
}

configure_auditd() {
    section "15" "Auditd"

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
-w /etc/login.defs -p wa -k auth_policy
-w /etc/security/pwquality.conf -p wa -k auth_policy
-w /etc/pam.d/common-password -p wa -k auth_policy
-w /etc/profile.d/70-veeam-shell-timeout.sh -p wa -k session_policy
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
    section "16" "Rsyslog e journald"

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
    section "17" "AppArmor"
    run "Check AppArmor status" aa-status || true
    info "AppArmor is left in enforcing mode when already present."
}

ensure_ufw_rule() {
    local desc="$1"
    shift
    run_or_die "$desc" ufw "$@"
}

configure_ufw() {
    section "18" "Firewall UFW"

    [[ "$ENABLE_UFW" == "yes" ]] || {
        info "UFW is left disabled by configuration."
        return 0
    }

    local ufw_active="no"
    local net rule

    ufw status 2>/dev/null | grep -q "Status: active" && ufw_active="yes"

    run_or_die "UFW default deny incoming" ufw default deny incoming
    run_or_die "UFW default allow outgoing" ufw default allow outgoing
    if [[ "$ufw_active" == "yes" ]]; then
        info "UFW is already active: no global reset will be performed, only the required rules will be added."
        warn "Existing UFW rules are preserved. Review them manually to remove legacy broad allows that would weaken the hardened baseline."
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
        ensure_ufw_rule "Allow Veeam installer 6160 from ${net}" allow from "$net" to any port 6160 proto tcp
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
    section "19" "GRUB protection"

    [[ "$SET_GRUB_PASSWORD" == "yes" ]] || {
        info "GRUB protection not requested."
        return 0
    }

    [[ -n "$GRUB_PBKDF2_HASH" || "$DRY_RUN" == "yes" ]] || die "Missing GRUB PBKDF2 hash."

    write_file "/etc/grub.d/01_veeam_superusers" "0755" "root" "root" <<EOF
set superusers="root"
password_pbkdf2 root ${GRUB_PBKDF2_HASH}
EOF

    run_or_die "Update GRUB" update-grub
}

lock_root_password_if_requested() {
    section "20" "Root password"

    [[ "$LOCK_ROOT_PASSWORD" == "yes" ]] || {
        info "Root password left unchanged by configuration."
        return 0
    }

    run_or_die "Lock root password" passwd -l root
}

configure_account_policy_post_attach() {
    section "21" "STIG account policy post-attach"

    set_spaced_kv_in_file "ENCRYPT_METHOD" "YESCRYPT" /etc/login.defs
    set_spaced_kv_in_file "FAILLOG_ENAB" "yes" /etc/login.defs
    set_line_matching_regex '^[#[:space:]]*[*][[:space:]]+hard[[:space:]]+maxlogins([[:space:]]|$)' '* hard maxlogins 10' /etc/security/limits.conf
}

configure_pam_post_attach() {
    section "22" "PAM lockout and password history"

    local faillock_file="/etc/security/faillock.conf"

    set_line_matching_regex '^[#[:space:]]*audit([[:space:]]|$)' 'audit' "$faillock_file"
    set_line_matching_regex '^[#[:space:]]*silent([[:space:]]|$)' 'silent' "$faillock_file"
    set_kv_in_file "deny" "3" "$faillock_file"
    set_kv_in_file "fail_interval" "900" "$faillock_file"
    set_kv_in_file "unlock_time" "900" "$faillock_file"
    set_line_matching_regex '^[#[:space:]]*enforce_for_root([[:space:]]|$)' 'enforce_for_root' /etc/security/pwquality.conf

    set_pam_module_line \
        "/etc/pam.d/common-auth" \
        '^[[:space:]]*auth[[:space:]].*pam_faillock[.]so[[:space:]]+authsucc([[:space:]]|$)' \
        'auth	sufficient			pam_faillock.so authsucc' \
        '^[[:space:]]*auth[[:space:]]*requisite[[:space:]].*pam_deny[.]so([[:space:]]|$)'

    set_pam_module_line \
        "/etc/pam.d/common-auth" \
        '^[[:space:]]*auth[[:space:]].*pam_faillock[.]so[[:space:]]+authfail([[:space:]]|$)' \
        'auth	[default=die]		pam_faillock.so authfail' \
        '^[[:space:]]*auth[[:space:]].*pam_faillock[.]so[[:space:]]+authsucc([[:space:]]|$)'

    set_pam_module_line \
        "/etc/pam.d/common-auth" \
        '^[[:space:]]*auth[[:space:]].*pam_faillock[.]so[[:space:]]+preauth([[:space:]]|$)' \
        'auth	required			pam_faillock.so preauth' \
        '^[[:space:]]*auth[[:space:]].*pam_unix[.]so([[:space:]]|$)'

    set_pam_module_line \
        "/etc/pam.d/common-auth" \
        '^[[:space:]]*auth[[:space:]].*pam_faildelay[.]so([[:space:]]|$)' \
        'auth	required			pam_faildelay.so delay=4000000' \
        '^[[:space:]]*auth[[:space:]].*pam_faillock[.]so[[:space:]]+preauth([[:space:]]|$)'

    set_pam_module_line \
        "/etc/pam.d/common-password" \
        '^[[:space:]]*password[[:space:]].*pam_pwquality[.]so([[:space:]]|$)' \
        'password	requisite			pam_pwquality.so retry=3 enforce_for_root' \
        '^[[:space:]]*password[[:space:]].*pam_unix[.]so([[:space:]]|$)'

    set_pam_module_line \
        "/etc/pam.d/common-password" \
        '^[[:space:]]*password[[:space:]]*[[]success=1[[:space:]]+default=ignore[]][[:space:]]*pam_unix[.]so([[:space:]]|$)' \
        'password	[success=1 default=ignore]	pam_unix.so obscure yescrypt remember=5' \
        '^[[:space:]]*password[[:space:]]*requisite[[:space:]].*pam_deny[.]so([[:space:]]|$)'
}

configure_auditd_post_attach() {
    section "23" "Auditd strict post-attach"

    write_file "/etc/audit/rules.d/60-veeam-stig-post-attach.rules" "0640" "root" "root" <<EOF
-w /etc/pam.d/common-auth -p wa -k auth_policy
-w /etc/security/faillock.conf -p wa -k auth_policy
-w /etc/security/limits.conf -p wa -k session_policy
-w /etc/issue -p wa -k banners
-w /etc/issue.net -p wa -k banners
-w /etc/motd -p wa -k banners
-w ${MOUNT_POINT} -p wa -k veeamrepo_mount
-w /var/log/sudo.log -p wa -k maintenance
-w /var/log/wtmp -p wa -k logins
-w /var/log/btmp -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-a always,exit -F path=/bin/su -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged-priv_change
-a always,exit -F path=/usr/bin/sudo -F perm=x -F auid>=1000 -F auid!=4294967295 -k priv_cmd
-a always,exit -F path=/usr/bin/sudoedit -F perm=x -F auid>=1000 -F auid!=4294967295 -k priv_cmd
-a always,exit -F path=/usr/bin/passwd -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged-passwd
-a always,exit -F path=/usr/bin/gpasswd -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged-gpasswd
-a always,exit -F path=/usr/bin/chage -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged-chage
-a always,exit -F path=/usr/sbin/usermod -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged-usermod
-a always,exit -F path=/usr/bin/crontab -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged-crontab
-a always,exit -F path=/usr/bin/mount -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged-mount
-a always,exit -F path=/usr/bin/umount -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged-umount
-a always,exit -F arch=b32 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_chng
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_chng
-a always,exit -F arch=b32 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=4294967295 -k perm_chng
-a always,exit -F arch=b64 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=4294967295 -k perm_chng
-a always,exit -F arch=b32 -S setxattr,fsetxattr,lsetxattr,removexattr,fremovexattr,lremovexattr -F auid>=1000 -F auid!=-1 -k perm_mod
-a always,exit -F arch=b64 -S setxattr,fsetxattr,lsetxattr,removexattr,fremovexattr,lremovexattr -F auid>=1000 -F auid!=-1 -k perm_mod
-a always,exit -F arch=b32 -S creat,open,openat,open_by_handle_at,truncate,ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=-1 -k perm_access
-a always,exit -F arch=b32 -S creat,open,openat,open_by_handle_at,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=-1 -k perm_access
-a always,exit -F arch=b64 -S creat,open,openat,open_by_handle_at,truncate,ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=-1 -k perm_access
-a always,exit -F arch=b64 -S creat,open,openat,open_by_handle_at,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=-1 -k perm_access
-a always,exit -F arch=b32 -S unlink,unlinkat,rename,renameat,rmdir -F auid>=1000 -F auid!=4294967295 -k delete
-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat,rmdir -F auid>=1000 -F auid!=4294967295 -k delete
-a always,exit -F arch=b32 -S init_module,finit_module,delete_module -F auid>=1000 -F auid!=4294967295 -k module_chng
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -F auid>=1000 -F auid!=4294967295 -k module_chng
-a always,exit -F arch=b32 -S execve -C uid!=euid -F euid=0 -F key=execpriv
-a always,exit -F arch=b32 -S execve -C gid!=egid -F egid=0 -F key=execpriv
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -F key=execpriv
-a always,exit -F arch=b64 -S execve -C gid!=egid -F egid=0 -F key=execpriv
EOF

    backup_file /etc/audit/auditd.conf
    set_kv_in_file "flush" "INCREMENTAL_ASYNC" /etc/audit/auditd.conf
    set_kv_in_file "freq" "50" /etc/audit/auditd.conf
    set_kv_in_file "admin_space_left_action" "SINGLE" /etc/audit/auditd.conf
    set_kv_in_file "disk_full_action" "SUSPEND" /etc/audit/auditd.conf
    set_kv_in_file "disk_error_action" "SYSLOG" /etc/audit/auditd.conf
    set_kv_in_file "action_mail_acct" "root" /etc/audit/auditd.conf

    run_or_die "Enable auditd" systemctl enable --now auditd
    run_or_die "Load strict audit rules" augenrules --load
}

configure_aide_post_attach() {
    section "24" "AIDE integrity monitoring"

    local mount_regex repo_regex
    local aide_db="/var/lib/aide/aide.db"
    local aide_db_gz="/var/lib/aide/aide.db.gz"

    if ! cmd_exists aideinit; then
        [[ "$DRY_RUN" == "yes" ]] || die "Missing command: aideinit"
        info "DRY-RUN assumes aideinit will be provided by the aide package installation step."
    fi
    mount_regex="$(escape_path_regex "$MOUNT_POINT")"
    repo_regex="$(escape_path_regex "$REPO_DIR")"

    write_file "/etc/aide/aide.conf.d/98-veeam-hardening-excludes" "0644" "root" "root" <<EOF
!${mount_regex}$ 0
!${mount_regex}/.*$ 0
!${repo_regex}$ 0
!${repo_regex}/.*$ 0
EOF

    set_kv_in_file "SILENTREPORTS" "no" /etc/default/aide
    if [[ -e "$aide_db" || -e "$aide_db_gz" ]]; then
        info "An AIDE database already exists. The current baseline is preserved."
        warn "If you intentionally want to accept the current filesystem as the new AIDE baseline, run aideinit -y -f manually after reviewing the host state."
    else
        run_or_die "Initialize AIDE database" aideinit -y -f
    fi

    if systemctl list-unit-files dailyaidecheck.timer 2>/dev/null | grep -Fq 'dailyaidecheck.timer'; then
        run_or_die "Enable AIDE daily check timer" systemctl enable --now dailyaidecheck.timer
    else
        info "AIDE daily timer was not found. Package defaults will be used."
    fi
}

enforce_sticky_bit_post_attach() {
    section "25" "Sticky bit on public directories"

    local fs_path dir fixed_count=0

    while read -r fs_path; do
        fs_path="$(normalize_dir_path "$fs_path")"
        [[ -n "$fs_path" ]] || continue

        case "$fs_path" in
            /proc|/sys|/dev|/run|/snap|/mnt|/mnt/*|/media|/media/*)
                continue
                ;;
        esac

        path_is_under_mountpoint "$fs_path" "$MOUNT_POINT" && continue

        while read -r dir; do
            [[ -n "$dir" ]] || continue
            case "$dir" in
                /mnt|/mnt/*|/media|/media/*)
                    continue
                    ;;
            esac
            if mountpoint_in_use "$dir" && [[ "$dir" != "$fs_path" ]]; then
                continue
            fi
            ((fixed_count += 1))
            run_or_die "Set sticky bit on ${dir}" chmod +t "$dir"
        done < <(find "$fs_path" -xdev -type d -perm -0002 ! -perm -1000 2>/dev/null || true)
    done < <(df --local -P 2>/dev/null | awk 'NR > 1 {print $6}' | sort -u)

    if (( fixed_count == 0 )); then
        ok "No world-writable directories without sticky bit were found on local filesystems."
    else
        ok "Sticky bit enforced on ${fixed_count} directories."
    fi
}

ensure_grub_cmdline_linux_arg() {
    local arg="$1"
    local file="/etc/default/grub"
    local tmp

    [[ -f "$file" ]] || return 0

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN ensure GRUB_CMDLINE_LINUX contains ${arg}"
        return 0
    fi

    tmp="$(mktemp)"
    awk -v arg="$arg" '
        BEGIN { done = 0 }
        {
            if ($0 ~ /^[#[:space:]]*GRUB_CMDLINE_LINUX=/) {
                done = 1
                value = $0
                sub(/^[^=]*="/, "", value)
                sub(/".*$/, "", value)
                count = split(value, parts, /[[:space:]]+/)
                out = ""
                found = 0
                for (i = 1; i <= count; i++) {
                    if (parts[i] == "") {
                        continue
                    }
                    if (parts[i] == arg) {
                        found = 1
                    }
                    out = out (out ? " " : "") parts[i]
                }
                if (!found) {
                    out = out (out ? " " : "") arg
                }
                printf "GRUB_CMDLINE_LINUX=\"%s\"\n", out
                next
            }
            print
        }
        END {
            if (!done) {
                printf "GRUB_CMDLINE_LINUX=\"%s\"\n", arg
            }
        }
    ' "$file" > "$tmp"
    backup_file "$file"
    install -o root -g root -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

configure_grub_audit_bootflag_post_attach() {
    section "26" "GRUB audit boot flag"

    if [[ ! -f /etc/default/grub ]] || ! cmd_exists update-grub; then
        info "GRUB tooling is not available on this system. Skipping audit=1 boot flag."
        return 0
    fi

    ensure_grub_cmdline_linux_arg "audit=1"
    run_or_die "Update GRUB" update-grub
    warn "Kernel boot parameter audit=1 configured. A reboot is required for this STIG control to take full effect."
}

configure_ssh_auth_policy_post_attach() {
    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN remove strict SSH auth drop-in if present"
    else
        rm -f /etc/ssh/sshd_config.d/95-veeam-lockdown.conf
    fi

    if [[ "$DISABLE_SSHD_AFTER_ATTACH" == "yes" ]]; then
        info "Global SSH authentication policy is irrelevant because SSHD will be disabled."
        return 0
    fi

    if alternate_admin_key_login_exists; then
        warn "An alternate sudo admin with authorized_keys was detected, but the script keeps global PasswordAuthentication unchanged to avoid accidental administrative lockout."
        warn "If you want stricter STIG alignment, disable SSH password authentication only after validating a real key-based admin login path end-to-end."
    else
        warn "No alternate sudo admin with authorized_keys was detected. Global SSH password authentication is left unchanged to avoid locking out administrative access."
    fi
}

# --------------------[ Post attach lockdown ]--------------------
configure_veeam_certs_permissions() {
    section "27" "Veeam certificates"

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

remove_veeam_sudo_access() {
    section "28" "Remove Veeam user sudo access"

    if [[ "$DRY_RUN" == "yes" ]]; then
        info "DRY-RUN remove /etc/sudoers.d/99-veeam-limited if present"
    else
        rm -f /etc/sudoers.d/99-veeam-limited
    fi

    if id -nG "$VEEAM_USER" 2>/dev/null | tr ' ' '\n' | grep -Fxq 'sudo'; then
        run_or_die "Remove ${VEEAM_USER} from sudo group" gpasswd -d "$VEEAM_USER" sudo
    else
        ok "${VEEAM_USER} is already not a member of the sudo group."
    fi
}

lockdown_ssh_after_attach() {
    section "29" "Lockdown SSH post-attach"

    ensure_sshd_include_dropins
    install -d -m 0755 /etc/ssh/sshd_config.d
    configure_ssh_auth_policy_post_attach

    if [[ "$DISABLE_SSH_FOR_USER_AFTER_ATTACH" == "yes" ]]; then
        write_file "/etc/ssh/sshd_config.d/99-veeamrepo-deny.conf" "0644" "root" "root" <<EOF
DenyUsers ${VEEAM_USER}
EOF
        run_or_die "Validate SSH configuration" sshd -t
        run_or_die "Reload SSH service" systemctl reload ssh
        ok "SSH access blocked for ${VEEAM_USER}."
    else
        if [[ "$DRY_RUN" == "yes" ]]; then
            info "DRY-RUN remove deny rule for ${VEEAM_USER} if present"
        else
            rm -f /etc/ssh/sshd_config.d/99-veeamrepo-deny.conf
        fi
        run_or_die "Validate SSH configuration" sshd -t
        run_or_die "Reload SSH service" systemctl reload ssh
        info "Per-user SSH lock is disabled by configuration."
    fi

    if [[ "$DISABLE_SSHD_AFTER_ATTACH" == "yes" ]]; then
        run_or_die "Disable SSH service" systemctl disable --now ssh
    else
        run_or_die "Enable SSH service" systemctl enable ssh
        run_or_die "Start SSH service" systemctl start ssh
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
    ui "  3. The allowed Veeam networks must include every backup server, proxy,"
    ui "     gateway or mount server that needs direct access to the repository."
    ui "  4. ${VEEAM_USER} remains in the sudo group during this phase,"
    ui "     so the initial onboarding with single-use credentials does not break."
}

show_next_steps_prepare() {
    section "32" "Next steps"

    cat <<EOF >&2
1. In Veeam Backup & Replication, add the Linux server/repository using:
   - single-use credentials
   - non-root user: ${VEEAM_USER}
   - home directory: /home/${VEEAM_USER}
   - immutable repository retention configured in the hardened repository wizard
   - network access from backup infrastructure components to the repository:
     22 for SSH onboarding, 6160 for installer service, 6162 and 2500:3300 for transport

2. If you want the Data Mover to remain persistent, temporarily keep root elevation available.
   This script intentionally leaves it available to avoid issues during the first attach.

3. For backup jobs targeting this repository, use only forward incremental chains
   with active full or synthetic full. Reverse incremental and forever forward
   incremental are not supported with hardened repository immutability.

4. Remember that .VBM metadata files remain mutable by design. The immutable data
   is the backup chain content, not the live metadata file updated on every run.

5. Before the post-attach lockdown, make sure you have a separate admin account
   in the sudo group, or at minimum verified local-console root recovery.

6. After the first successful attach, run:
   sudo $0 --phase post-attach-lockdown --veeam-user ${VEEAM_USER} --veeam-group ${VEEAM_GROUP}

7. If a new password was generated, you can find it in:
   /root/.veeam_repo_credentials_${TIMESTAMP}
EOF
}

show_lockdown_summary() {
    section "33" "Post-attach lockdown summary"

    cat <<EOF >&2
  Veeam user                : ${VEEAM_USER}
  STIG-style PAM lockout    : enabled
  Password history          : remember 5
  AIDE                      : enabled
  Auditd strict rules       : enabled
  Sticky bit enforcement    : applied on local filesystems
  Full sudo                 : removed
  Limited sudo              : not granted
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
    read -r -p "To confirm, type exactly: WIPE ${BACKUP_DISK}: " typed || die "Input stream closed while waiting for destructive action confirmation."
    [[ "$typed" == "WIPE ${BACKUP_DISK}" ]] || die "Invalid confirmation. Operation cancelled."
    ok "Destructive action confirmed."
}

final_confirm() {
    [[ "$INTERACTIVE" == "yes" ]] || return 0
    local proceed
    ask_yes_no_default "Do you want to continue?" "no"
    proceed="$PROMPT_RESULT"
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
    configure_account_policy_prepare
    configure_password_quality_prepare
    configure_time_sync_prepare
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
    install_lockdown_packages
    configure_account_policy_post_attach
    configure_pam_post_attach
    configure_auditd_post_attach
    configure_aide_post_attach
    enforce_sticky_bit_post_attach
    configure_grub_audit_bootflag_post_attach
    configure_veeam_certs_permissions
    remove_veeam_sudo_access
    lockdown_ssh_after_attach
    show_lockdown_summary
}

main() {
    parse_args "$@"
    require_root
    ensure_timezone_europe_rome
    init_logging
    maybe_load_prepare_state
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