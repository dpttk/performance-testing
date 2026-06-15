#!/usr/bin/env bash
# Performance benchmark orchestrator (core metric set).

set -euo pipefail

# shellcheck source=scripts/lib/runtime.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime.sh"
# shellcheck source=scripts/lib/stats.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stats.sh"
# shellcheck source=scripts/lib/measurement.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/measurement.sh"
# shellcheck source=scripts/lib/bench.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bench.sh"

: "${PERF_METRICS:=latency cpu_mem network app}"

run_perf_suite() {
    local out_dir="$1"
    shift || true
    local requested=("$@")
    local metrics=("${requested[@]}")
    [[ ${#metrics[@]} -eq 0 ]] && read -r -a metrics <<<"$PERF_METRICS"

    pin_cpu_governor >/dev/null || true
    capture_host_metadata "$out_dir/host-metadata.txt"

    local baseline=()
    local alias
    for alias in $RUNTIMES; do
        if runtime_available "$alias"; then
            baseline+=("$alias")
        else
            warn "Runtime '$alias' unavailable; excluding."
        fi
    done

    local enforced=()
    if runtime_available hardened_enforced; then
        enforced+=(hardened_enforced)
    else
        warn "hardened_enforced unavailable (run profile stage first)."
    fi

    local active=("${baseline[@]}" "${enforced[@]}")
    [[ ${#active[@]} -gt 0 ]] || error "No runtimes available for benchmarking."
    echo "${active[*]}" >"$out_dir/active-runtimes.txt"
    info "Benchmark runtimes: ${active[*]}"

    run_metric() {
        case "$1" in
            latency) bench_latency "$out_dir" "${active[@]}" ;;
            cpu_mem) bench_cpu_mem "$out_dir" "${baseline[@]}" ;;
            network) bench_network "$out_dir" "${baseline[@]}" ;;
            app) bench_app_redis "$out_dir" "${baseline[@]}" ;;
            *) warn "Unknown metric '$1'";;
        esac
    }

    local m
    for m in "${metrics[@]}"; do
        info "--- metric: $m ---"
        run_metric "$m" || warn "Metric '$m' failed; continuing"
    done
}

