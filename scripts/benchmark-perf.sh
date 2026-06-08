#!/usr/bin/env bash
# Performance benchmark suite (raw mode).
#
# Runs the full multi-runtime, multi-metric performance matrix with statistical
# rigor (warmup + repeated samples, median/p95/p99/stddev) and writes one JSON
# file per metric under results/perf-<timestamp>/.
#
# Usage:
#   sudo ./scripts/benchmark-perf.sh                 # all metrics
#   sudo ./scripts/benchmark-perf.sh latency density # selected metrics

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/stats.sh
source "$SCRIPT_DIR/lib/stats.sh"
# shellcheck source=scripts/lib/measurement.sh
source "$SCRIPT_DIR/lib/measurement.sh"
# shellcheck source=scripts/lib/bench.sh
source "$SCRIPT_DIR/lib/bench.sh"

require_root

METRICS=("$@")
[[ ${#METRICS[@]} -eq 0 ]] && METRICS=(latency density cpu_mem disk network app)

# Honour a shared campaign directory (set by run-all.sh) so every suite writes
# into one results dir; otherwise create a standalone perf-<timestamp> dir.
OUT_DIR="${RUN_DIR:-$(ensure_results_dir "perf-$(date +%Y%m%d-%H%M%S)")}"
mkdir -p "$OUT_DIR"
info "Performance results: $OUT_DIR"

pin_cpu_governor >/dev/null || true
capture_host_metadata "$OUT_DIR/host-metadata.txt"

# Resolve active runtimes: configured RUNTIMES that are actually launchable.
ACTIVE=()
for alias in $RUNTIMES; do
    if runtime_available "$alias"; then
        ACTIVE+=("$alias")
    else
        warn "Runtime '$alias' unavailable on this host; excluding from run."
    fi
done
[[ ${#ACTIVE[@]} -gt 0 ]] || error "No runtimes available. Check setup.sh / install-docker.sh."
info "Active runtimes: ${ACTIVE[*]}"
echo "${ACTIVE[*]}" >"$OUT_DIR/active-runtimes.txt"

run_metric() {
    case "$1" in
        latency) bench_latency "$OUT_DIR" "${ACTIVE[@]}" ;;
        density) bench_density "$OUT_DIR" "${ACTIVE[@]}" ;;
        cpu_mem) bench_cpu_mem "$OUT_DIR" "${ACTIVE[@]}" ;;
        disk)    bench_disk "$OUT_DIR" "${ACTIVE[@]}" ;;
        network) bench_network "$OUT_DIR" "${ACTIVE[@]}" ;;
        app)     bench_app_redis "$OUT_DIR" "${ACTIVE[@]}" ;;
        *) warn "Unknown metric: $1" ;;
    esac
}

for m in "${METRICS[@]}"; do
    info "--- metric: $m ---"
    run_metric "$m" || warn "metric '$m' failed; continuing"
done

info "Performance suite complete: $OUT_DIR"
info "Aggregate with: sudo ./scripts/report.sh $OUT_DIR"
