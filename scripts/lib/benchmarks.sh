#!/usr/bin/env bash
# Performance benchmark orchestrator.

set -euo pipefail

# shellcheck source=scripts/lib/runtime.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime.sh"
# shellcheck source=scripts/lib/stats.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stats.sh"
# shellcheck source=scripts/lib/measurement.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/measurement.sh"
# shellcheck source=scripts/lib/bench.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench.sh"

: "${PERF_METRICS:=sysbench-cpu sysbench-mem network-iperf redis-app}"

run_perf_suite() {
    local out_dir="$1"
    shift || true
    local requested=("$@")
    local metrics=("${requested[@]}")
    [[ ${#metrics[@]} -eq 0 ]] && metrics=("${WORKLOAD_IDS[@]}")

    pin_cpu_governor >/dev/null || true
    capture_host_metadata "$out_dir/host-metadata.txt"

    local active=()
    local alias
    for alias in $RUNTIMES; do
        if runtime_available "$alias"; then
            active+=("$alias")
        else
            warn "Runtime '$alias' unavailable; excluding."
        fi
    done
    [[ ${#active[@]} -gt 0 ]] || error "No runtimes available for benchmarking."
    echo "${active[*]}" >"$out_dir/active-runtimes.txt"
    info "Benchmark runtimes: ${active[*]}"

    local m
    for m in "${metrics[@]}"; do
        info "--- workload: $m ---"
        bench_workload "$m" "$out_dir" "${active[@]}" || warn "Workload '$m' failed; continuing"
    done
}
