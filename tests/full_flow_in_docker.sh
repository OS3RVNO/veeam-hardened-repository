#!/usr/bin/env bash
# Run the full prepare -> post-attach-lockdown flow in privileged Docker
# containers. Requires a Linux host with Docker and the scsi_debug module.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
LOG_DIR="${ROOT_DIR}/flow_logs_$(date +%Y%m%d_%H%M%S)"
KEEP_TEST_ENV="${KEEP_TEST_ENV:-no}"
mkdir -p "$LOG_DIR"

VERSIONS=("22.04" "24.04")
TAGS=("2204" "2404")
CONTAINERS=("veeam-flow-2204" "veeam-flow-2404")
VGS=("vg_veeam_2204" "vg_veeam_2404")
DISKS=()

log() {
    printf '%s\n' "$*"
}

run_logged() {
    local name="$1"
    local logfile="$2"
    local cmd="$3"
    local rc

    log ""
    log ">>> ${name}"
    set +e
    bash -lc "$cmd" 2>&1 | tee "$logfile"
    rc=${PIPESTATUS[0]}
    set -e
    log "<<< ${name}: rc=${rc}"
    return "$rc"
}

run_call_logged() {
    local name="$1"
    local logfile="$2"
    local rc
    shift 2

    log ""
    log ">>> ${name}"
    set +e
    "$@" 2>&1 | tee "$logfile"
    rc=${PIPESTATUS[0]}
    set -e
    log "<<< ${name}: rc=${rc}"
    return "$rc"
}

docker_exec_logged() {
    local container="$1"
    local logfile="$2"
    local cmd="$3"
    local rc

    log ""
    log ">>> ${container}: ${cmd}"
    set +e
    docker exec "$container" bash -lc "$cmd" 2>&1 | tee "$logfile"
    rc=${PIPESTATUS[0]}
    set -e
    log "<<< ${container}: rc=${rc}"
    return "$rc"
}

cleanup_previous_run() {
    local container vg

    for container in "${CONTAINERS[@]}"; do
        docker rm -f "$container" >/dev/null 2>&1 || true
    done

    for vg in "${VGS[@]}"; do
        vgchange -an "$vg" >/dev/null 2>&1 || true
    done
}

cleanup_test_environment() {
    local container vg

    if [[ "$KEEP_TEST_ENV" == "yes" ]]; then
        log "KEEP_TEST_ENV=yes: containers and test disks were left available."
        return 0
    fi

    for container in "${CONTAINERS[@]}"; do
        docker rm -f "$container" >/dev/null 2>&1 || true
    done

    for vg in "${VGS[@]}"; do
        vgchange -an "$vg" >/dev/null 2>&1 || true
    done

    if lsmod | grep -q '^scsi_debug'; then
        modprobe -r scsi_debug >/dev/null 2>&1 || true
    fi
}

wait_for_systemd() {
    local container="$1"
    local i state

    for i in {1..60}; do
        state="$(docker exec "$container" bash -lc 'systemctl is-system-running 2>/dev/null || true' || true)"
        case "$state" in
            running|degraded)
                log "${container}: systemd state=${state}"
                return 0
                ;;
        esac
        sleep 2
    done

    docker logs "$container" >&2 || true
    return 1
}

build_image() {
    local version="$1"
    local tag="$2"
    local image="veeam-flow-systemd:${tag}"
    local dockerfile="${LOG_DIR}/Dockerfile.${tag}"

    cat > "$dockerfile" <<EOF
FROM ubuntu:${version}
ENV container=docker
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Rome
RUN apt-get update \\
    && apt-get install -y --no-install-recommends \\
        systemd systemd-sysv dbus udev sudo passwd procps kmod util-linux tzdata ca-certificates \\
    && ln -snf /usr/share/zoneinfo/Europe/Rome /etc/localtime \\
    && echo Europe/Rome > /etc/timezone \\
    && apt-get clean \\
    && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF

    docker build -t "$image" -f "$dockerfile" "$LOG_DIR"
}

prepare_scsi_debug_disks() {
    if lsmod | grep -q '^scsi_debug'; then
        log "scsi_debug is already loaded; removing it before creating fresh test disks."
        modprobe -r scsi_debug
    fi

    modprobe scsi_debug dev_size_mb=1024 add_host=2 per_host_store=1 num_tgts=1
    udevadm settle 2>/dev/null || sleep 2

    mapfile -t DISKS < <(lsblk -b -dn -o NAME,SIZE,MODEL | awk '$2 == 1073741824 && $0 ~ /scsi_debug/ {print "/dev/" $1}' | sort)
    if (( ${#DISKS[@]} < 2 )); then
        lsblk -dn -o NAME,TYPE,SIZE,MODEL >&2 || true
        log "Expected two 1GB scsi_debug disks, found ${#DISKS[@]}." >&2
        return 1
    fi

    log "Using test disks: ${DISKS[0]} ${DISKS[1]}"
}

start_container() {
    local tag="$1"
    local container="$2"
    local image="veeam-flow-systemd:${tag}"

    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d \
        --name "$container" \
        --privileged \
        --security-opt seccomp=unconfined \
        --cgroupns=private \
        --tmpfs /run \
        --tmpfs /run/lock \
        "$image" >/dev/null
    wait_for_systemd "$container"
}

seed_container() {
    local container="$1"

    docker cp "${ROOT_DIR}/veeam_hardened_repository_safe.sh" "${container}:/root/veeam_hardened_repository_safe.sh"
    docker exec "$container" bash -lc 'chmod 700 /root/veeam_hardened_repository_safe.sh'
    docker exec "$container" bash -lc 'userdel -r adminflow >/dev/null 2>&1 || true; useradd -m -s /bin/bash adminflow; usermod -aG sudo adminflow; printf "%s:%s\n" adminflow "Veeam-Test-Admin-Password-1!" | chpasswd'
    docker exec "$container" bash -lc '
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y lvm2 xfsprogs gdisk parted util-linux
        mkdir -p /etc/lvm
        cat > /etc/lvm/lvmlocal.conf <<'"'"'LVMEOF'"'"'
activation {
    udev_sync = 0
    udev_rules = 0
    verify_udev_operations = 0
}
LVMEOF
        rm -f /etc/lvm/devices/system.devices /run/lvm/hints /etc/lvm/hints
    '
}

collect_debug() {
    local container="$1"
    local logfile="${LOG_DIR}/${container}_debug.log"

    log ""
    log ">>> ${container}: collecting debug"
    set +e
    docker exec "$container" bash -lc '
        set +e
        echo "--- os-release"
        cat /etc/os-release
        echo "--- recent veeam logs"
        for d in $(ls -td /var/log/veeam-hardened-repo/run_* 2>/dev/null); do
            echo "### ${d}/main.log"
            tail -200 "${d}/main.log" 2>/dev/null
        done
        echo "--- lsblk"
        lsblk -f
        echo "--- pvs"
        pvs -a 2>&1
        echo "--- vgs"
        vgs 2>&1
        echo "--- lvs"
        lvs 2>&1
        echo "--- systemd"
        systemctl is-system-running 2>&1 || true
        echo "--- journal"
        journalctl -n 120 --no-pager 2>&1
    ' 2>&1 | tee "$logfile"
    set -e
    log "<<< ${container}: debug collected"
}

run_flow() {
    local idx="$1"
    local tag="${TAGS[$idx]}"
    local container="${CONTAINERS[$idx]}"
    local disk="${DISKS[$idx]}"
    local vg="${VGS[$idx]}"
    local common_args

    common_args="--non-interactive --mount /veeamrepo --repo-dir /veeamrepo/backup --veeam-user veeamrepo --veeam-group veeamrepo --vg ${vg} --lv lv_repo --enable-auditd no"

    docker_exec_logged "$container" "${LOG_DIR}/${container}_precheck.log" \
        "VEEAM_TEST_ALLOW_UNKNOWN_SYSTEM_DISK=yes /root/veeam_hardened_repository_safe.sh --phase prepare --precheck-only ${common_args} --disk ${disk} --use-partition no --ssh-net 172.16.0.0/12 --veeam-net 172.16.0.0/12" || {
        collect_debug "$container"
        return 1
    }

    docker_exec_logged "$container" "${LOG_DIR}/${container}_prepare.log" \
        "VEEAM_TEST_ALLOW_UNKNOWN_SYSTEM_DISK=yes /root/veeam_hardened_repository_safe.sh --phase prepare ${common_args} --disk ${disk} --use-partition no --ssh-net 172.16.0.0/12 --veeam-net 172.16.0.0/12" || {
        collect_debug "$container"
        return 1
    }

    docker_exec_logged "$container" "${LOG_DIR}/${container}_prepare_verify.log" \
        "findmnt /veeamrepo && findmnt /veeamrepo/backup >/dev/null 2>&1 || true; lsblk -f ${disk}; lvs; id veeamrepo; id -nG veeamrepo; test -d /veeamrepo/backup" || {
        collect_debug "$container"
        return 1
    }

    docker_exec_logged "$container" "${LOG_DIR}/${container}_seed_certs.log" \
        "install -d -m 0750 -o veeamrepo -g veeamrepo /opt/veeam/transport/certs && touch /opt/veeam/transport/certs/test-cert.pem && chown veeamrepo:veeamrepo /opt/veeam/transport/certs/test-cert.pem" || {
        collect_debug "$container"
        return 1
    }

    docker_exec_logged "$container" "${LOG_DIR}/${container}_lockdown.log" \
        "/root/veeam_hardened_repository_safe.sh --phase post-attach-lockdown ${common_args}" || {
        collect_debug "$container"
        return 1
    }

    docker_exec_logged "$container" "${LOG_DIR}/${container}_lockdown_verify.log" \
        "findmnt /veeamrepo; ls -ld /veeamrepo /veeamrepo/backup /opt/veeam/transport/certs; id -nG veeamrepo; ! id -nG veeamrepo | grep -qw sudo; systemctl is-active ssh || true; systemctl is-active auditd || true" || {
        collect_debug "$container"
        return 1
    }

    {
        printf '%s\n' "container=${container}"
        printf '%s\n' "ubuntu_tag=${tag}"
        printf '%s\n' "disk=${disk}"
        printf '%s\n' "vg=${vg}"
        docker exec "$container" bash -lc "grep PRETTY_NAME /etc/os-release; findmnt -n -o SOURCE,TARGET,FSTYPE /veeamrepo; lvs --units b --nosuffix --noheadings -o vg_name,lv_name,lv_size '${vg}/lv_repo'; id -nG veeamrepo"
    } > "${LOG_DIR}/${container}_summary.txt"
}

main() {
    log "Logs: ${LOG_DIR}"
    trap cleanup_test_environment EXIT

    command -v docker >/dev/null
    command -v modprobe >/dev/null
    command -v lsblk >/dev/null

    for i in "${!VERSIONS[@]}"; do
        run_call_logged "build Ubuntu ${VERSIONS[$i]} systemd image" "${LOG_DIR}/build_${TAGS[$i]}.log" \
            build_image "${VERSIONS[$i]}" "${TAGS[$i]}"
    done

    cleanup_previous_run
    prepare_scsi_debug_disks

    for i in "${!CONTAINERS[@]}"; do
        start_container "${TAGS[$i]}" "${CONTAINERS[$i]}"
        seed_container "${CONTAINERS[$i]}"
    done

    local failures=0
    for i in "${!CONTAINERS[@]}"; do
        if ! run_flow "$i"; then
            failures=$((failures + 1))
        fi
    done

    {
        printf '%s\n' "logs=${LOG_DIR}"
        printf '%s\n' "containers=${CONTAINERS[*]}"
        printf '%s\n' "disks=${DISKS[*]}"
        for container in "${CONTAINERS[@]}"; do
            printf '\n[%s]\n' "$container"
            if [[ -f "${LOG_DIR}/${container}_summary.txt" ]]; then
                cat "${LOG_DIR}/${container}_summary.txt"
            else
                printf '%s\n' "summary=not-created"
            fi
        done
    } | tee "${LOG_DIR}/summary.txt"

    return "$failures"
}

main "$@"
