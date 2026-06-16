#!/usr/bin/env bash
# Measurement-hygiene helpers: CPU governor pinning, workload core pinning, and
# rich host-metadata capture so benchmark runs are reproducible and citable.

# Pin all CPUs to the performance governor (best-effort; no-op when cpufreq is
# unavailable, e.g. inside some VMs). Returns the previous governor via stdout.
pin_cpu_governor() {
    [[ "${PIN_CPU_GOVERNOR:-1}" == "1" ]] || return 0
    local gov_file=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
    [[ -w "$gov_file" ]] || { warn "cpufreq governor not writable; skipping CPU pinning (expected in some VMs)"; return 0; }
    local prev
    prev="$(cat "$gov_file" 2>/dev/null || echo unknown)"
    local f
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance >"$f" 2>/dev/null || true
    done
    info "CPU governor set to performance (was: $prev)"
    echo "$prev"
}

# Wrap a command with taskset when PIN_CPU_CORES is configured.
pin_cmd() {
    if [[ -n "${PIN_CPU_CORES:-}" ]] && command -v taskset >/dev/null 2>&1; then
        taskset -c "$PIN_CPU_CORES" "$@"
    else
        "$@"
    fi
}

# Drop page cache between disk-sensitive runs (best-effort).
drop_caches() {
    sync || true
    echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
}

# Capture a detailed host-metadata file for a results directory.
capture_host_metadata() {
    local out="$1"
    {
        echo "host=$(hostname)"
        echo "date=$(date -Iseconds)"
        echo "kernel=$(uname -r)"
        echo "arch=$(uname -m)"
        echo "cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ //')"
        echo "cpu_count=$(nproc)"
        echo "virt=$(systemd-detect-virt 2>/dev/null || echo unknown)"
        echo "kvm_present=$([[ -e /dev/kvm ]] && echo yes || echo no)"
        echo "mem_total=$(grep -m1 MemTotal /proc/meminfo 2>/dev/null | awk '{print $2" "$3}')"
        echo "cgroup=$(stat -fc %T /sys/fs/cgroup 2>/dev/null)"
        echo "cpu_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
        echo "turbo_disabled=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a)"
        echo "os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
        echo "containerd=$(containerd --version 2>/dev/null | head -1)"
        echo "docker=$(${DOCKER_BIN:-docker} --version 2>/dev/null | head -1 || echo missing)"
        echo "runc_stock=$($RUNC_STOCK_BIN --version 2>/dev/null | head -1 || echo missing)"
        echo "runc_proposed=$($RUNC_PROPOSED_BIN --version 2>/dev/null | head -1 || echo missing)"
        echo "runsc=$($RUNSC_BIN --version 2>/dev/null | head -1 || echo missing)"
        echo "kata=$(command -v containerd-shim-kata-v2 >/dev/null 2>&1 && echo present || echo missing)"
        echo "runtimes_under_test=$RUNTIMES"
        echo "reps=$REPS warmup=$WARMUP"
        echo "profiles_dir=$PROFILES_DIR"
        echo "launcher_stock=$(runtime_launcher stock)"
        echo "launcher_proposed=$(runtime_launcher proposed)"
        echo "launcher_gvisor=$(runtime_launcher gvisor)"
        echo "launcher_docker=$(runtime_launcher docker)"
    } >"$out"
}

# Snapshot used memory in MiB (for density footprint deltas).
used_mem_mib() {
    awk '/MemAvailable/ {avail=$2} /MemTotal/ {total=$2} END {printf "%.1f", (total-avail)/1024}' /proc/meminfo
}
