#!/usr/bin/env bash
# One-command end-to-end evaluation campaign.
#
# Runs the full performance + security matrix into a single timestamped results
# directory and produces the aggregated report (CSV + Markdown + plots):
#
#   1. performance suite (latency, density, cpu/mem, disk, network, app)
#   2. profile generation via --security-scan (+ scan-time cost)
#   3. enforcement-mode overhead (raw vs enforced bundle)
#   4. attack-surface metrics
#   5. post-RCE confinement matrix
#   6. aggregated report
#
# Usage:
#   sudo ./scripts/run-all.sh                 # full campaign, default workloads
#   sudo ./scripts/run-all.sh --quick         # fast smoke run (small reps)
#   sudo ./scripts/run-all.sh --skip-perf     # security only
#   sudo ./scripts/run-all.sh --skip-security # performance only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/measurement.sh"

require_root

DO_PERF=1
DO_SECURITY=1
SCAN_WORKLOAD_NAME="syscalls"
SCAN_IMAGE="$BUSYBOX_IMAGE"

for arg in "$@"; do
    case "$arg" in
        --quick)
            export REPS=8 WARMUP=2 SYSBENCH_REPS=2 DISK_REPS=2 \
                   IPERF_DURATION=4 REDIS_BENCH_REQUESTS=30000 DENSITY_SIZES="3 5 10"
            info "Quick mode: reduced sample counts."
            ;;
        --skip-perf) DO_PERF=0 ;;
        --skip-security) DO_SECURITY=0 ;;
        -h|--help)
            sed -n '2,20p' "$0"; exit 0 ;;
        *) error "Unknown argument: $arg" ;;
    esac
done

RUN_DIR="$(ensure_results_dir "campaign-$(date +%Y%m%d-%H%M%S)")"
export RUN_DIR
info "==================================================================="
info " Evaluation campaign: $RUN_DIR"
info "==================================================================="

pin_cpu_governor >/dev/null || true
capture_host_metadata "$RUN_DIR/host-metadata.txt"

if [[ "$DO_PERF" -eq 1 ]]; then
    info ">>> [1/6] Performance suite"
    "$SCRIPT_DIR/benchmark-perf.sh" || warn "performance suite reported errors"
fi

if [[ "$DO_SECURITY" -eq 1 ]]; then
    info ">>> [2/6] Profile generation (--security-scan)"
    "$SCRIPT_DIR/security/generate-profile.sh" "$SCAN_WORKLOAD_NAME" "$SCAN_IMAGE" || \
        warn "profile generation reported errors"

    info ">>> [3/6] Enforcement-mode overhead"
    "$SCRIPT_DIR/security/enforcement-bench.sh" "$SCAN_WORKLOAD_NAME" "$RUN_DIR" || \
        warn "enforcement benchmark reported errors"

    info ">>> [4/6] Attack-surface metrics"
    "$SCRIPT_DIR/security/surface-metrics.sh" "$RUN_DIR" "$SCAN_WORKLOAD_NAME" || \
        warn "surface metrics reported errors"

    info ">>> [5/6] Post-RCE confinement matrix"
    "$SCRIPT_DIR/security/attack-matrix.sh" "$RUN_DIR" "$SCAN_WORKLOAD_NAME" || \
        warn "attack matrix reported errors"
fi

info ">>> [6/6] Aggregating report"
"$SCRIPT_DIR/report.sh" "$RUN_DIR" || warn "report generation reported errors"

# Reproducibility snapshot.
cp "$PERF_DIR/config.env" "$RUN_DIR/config.env.used" 2>/dev/null || true

info "==================================================================="
info " Campaign complete."
info "   Results : $RUN_DIR"
info "   Report  : $RUN_DIR/report.md"
info "   CSV     : $RUN_DIR/report.csv"
info "   Plots   : $RUN_DIR/plots/"
info "==================================================================="
