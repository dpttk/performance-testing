#!/usr/bin/env bash
# Canonical workload definitions for profile generation and benchmarking.
# Every runtime executes the same command strings defined here.

set -euo pipefail

[[ -n "${PERF_DIR:-}" ]] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Ordered workload identifiers (one security profile per workload).
WORKLOAD_IDS=(sysbench-cpu sysbench-mem network-iperf redis-app)

workload_image() {
    case "$1" in
        sysbench-cpu|sysbench-mem) echo "$SYSBENCH_IMAGE" ;;
        network-iperf) echo "$IPERF_IMAGE" ;;
        redis-app) echo "$REDIS_IMAGE" ;;
        *) error "Unknown workload: $1" ;;
    esac
}

# Shell command executed inside the container (identical for all runtimes).
workload_command() {
    case "$1" in
        sysbench-cpu)
            echo "sysbench cpu --cpu-max-prime=20000 --threads=1 run"
            ;;
        sysbench-mem)
            echo "sysbench memory --memory-total-size=2G --threads=1 run"
            ;;
        network-iperf)
            echo "iperf3 -s & sleep 2; iperf3 -c 127.0.0.1 -t ${IPERF_DURATION} -P ${IPERF_PARALLEL} -J; kill \$(jobs -p) 2>/dev/null || true"
            ;;
        redis-app)
            echo "redis-server --daemonize yes --save '' --appendonly no >/dev/null 2>&1; sleep 1; redis-benchmark -q -n ${REDIS_BENCH_REQUESTS} -c ${REDIS_BENCH_CLIENTS} -P ${REDIS_BENCH_PIPELINE} -t set,get"
            ;;
        *) error "Unknown workload: $1" ;;
    esac
}

workload_profile_dir() {
    echo "$PROFILES_DIR/$1"
}

workload_rootfs_dir() {
    echo "$(workload_profile_dir "$1")/rootfs"
}

workload_metric_file() {
    case "$1" in
        sysbench-cpu) echo "sysbench-cpu.json" ;;
        sysbench-mem) echo "sysbench-mem.json" ;;
        network-iperf) echo "network.json" ;;
        redis-app) echo "redis-app.json" ;;
        *) error "Unknown workload metric file for: $1" ;;
    esac
}

workload_metric_name() {
    case "$1" in
        sysbench-cpu) echo "sysbench_cpu" ;;
        sysbench-mem) echo "sysbench_memory" ;;
        network-iperf) echo "network_throughput" ;;
        redis-app) echo "redis_app" ;;
        *) error "Unknown workload metric name for: $1" ;;
    esac
}

workload_unit() {
    case "$1" in
        sysbench-cpu) echo "events_per_sec" ;;
        sysbench-mem) echo "MiB_per_sec" ;;
        network-iperf) echo "Gbit_per_sec" ;;
        redis-app) echo "requests_per_sec" ;;
        *) error "Unknown workload unit for: $1" ;;
    esac
}

# Parse primary throughput value from captured workload output.
workload_parse_value() {
    local wl="$1" out="$2"
    case "$wl" in
        sysbench-cpu)
            echo "$out" | awk '/events per second/ {gsub(/ /,"",$NF); print $NF; exit}'
            ;;
        sysbench-mem)
            echo "$out" | python3 -c 'import sys,re
m=re.search(r"\(([0-9.]+)", sys.stdin.read())
print(m.group(1) if m else "")' 2>/dev/null
            ;;
        network-iperf)
            echo "$out" | awk '/Gbits\/sec/ && /receiver/ {print $(NF-2); exit}'
            ;;
        redis-app)
            # Prints "set<TAB>get" on one line for dual-metric workloads.
            local sv gv
            sv="$(echo "$out" | tr '\r' '\n' | awk '/^SET: [0-9]/{print $2; exit}')"
            gv="$(echo "$out" | tr '\r' '\n' | awk '/^GET: [0-9]/{print $2; exit}')"
            echo "${sv}	${gv}"
            ;;
        *) error "Unknown workload parser: $wl" ;;
    esac
}

# Return 0 when output contains a valid workload result.
workload_output_valid() {
    local wl="$1" out="$2"
    case "$wl" in
        sysbench-cpu|sysbench-mem|network-iperf)
            [[ -n "$(workload_parse_value "$wl" "$out")" ]]
            ;;
        redis-app)
            local v
            v="$(workload_parse_value "$wl" "$out")"
            [[ -n "${v%%	*}" && -n "${v##*	}" ]]
            ;;
        *) return 1 ;;
    esac
}

# Functional equivalence: both variants complete and emit valid workload output.
# Throughput values may differ between runs; semantics are preserved when both parse.
workload_functionally_equivalent() {
    local wl="$1" raw_out="$2" enf_out="$3"
    workload_output_valid "$wl" "$raw_out" && workload_output_valid "$wl" "$enf_out"
}

workload_description() {
    case "$1" in
        sysbench-cpu) echo "sysbench CPU events per second" ;;
        sysbench-mem) echo "sysbench memory transfer MiB per second" ;;
        network-iperf) echo "iperf3 loopback receiver throughput Gbit per second" ;;
        redis-app) echo "redis-benchmark SET and GET throughput req per second" ;;
        *) error "Unknown workload description: $1" ;;
    esac
}
