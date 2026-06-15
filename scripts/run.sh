#!/usr/bin/env bash
# Unified enforced-first pipeline:
#   verify -> profile scan/apply/functional-check -> perf benchmarks -> report

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/profile.sh
source "$SCRIPT_DIR/lib/profile.sh"

require_root

QUICK=0
METRICS=()
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        latency|cpu_mem|network|app) METRICS+=("$arg") ;;
        -h|--help)
            cat <<'EOF'
Usage: sudo ./scripts/run.sh [--quick] [latency cpu_mem network app]

Runs the complete enforced-first campaign:
  1) host/runtime verification
  2) synthetic profile generation with --security-scan
  3) functional check + enforcement overhead measurement
  4) baseline performance benchmarks (stock/gvisor/docker)
  5) aggregate Markdown + CSV report
EOF
            exit 0
            ;;
        *) error "Unknown argument: $arg" ;;
    esac
done

if [[ "$QUICK" -eq 1 ]]; then
    export REPS=8 WARMUP=2 SYSBENCH_REPS=2 IPERF_DURATION=4 REDIS_BENCH_REQUESTS=30000
    info "Quick mode enabled."
fi

RUN_DIR="$(ensure_results_dir "campaign-$(date +%Y%m%d-%H%M%S)")"
export RUN_DIR
mkdir -p "$RUN_DIR"

info "=== [1/5] Verify host prerequisites ==="
"$SCRIPT_DIR/verify.sh"

info "=== [2/5] Scan/apply profile for synthetic workload ==="
profile_generate_bundle "$PROFILE_NAME" "$PROFILE_IMAGE" "$PROFILE_COMMAND"

info "=== [3/5] Functional check + enforcement overhead ==="
profile_measure_enforcement "$PROFILE_NAME" "$RUN_DIR"

info "=== [4/5] Baseline performance benchmarks ==="
if [[ ${#METRICS[@]} -eq 0 ]]; then
    "$SCRIPT_DIR/benchmark-perf.sh"
else
    "$SCRIPT_DIR/benchmark-perf.sh" "${METRICS[@]}"
fi

info "=== [5/5] Aggregate report ==="
"$SCRIPT_DIR/report.sh" "$RUN_DIR"

cp "$PERF_DIR/config.env" "$RUN_DIR/config.env.used" 2>/dev/null || true

LATEST_DIR="$PERF_DIR/results/latest"
mkdir -p "$LATEST_DIR"
rsync -a --delete "$RUN_DIR/" "$LATEST_DIR/" 2>/dev/null || {
    rm -rf "$LATEST_DIR"
    mkdir -p "$LATEST_DIR"
    cp -a "$RUN_DIR/." "$LATEST_DIR/"
}
info "Published snapshot: $LATEST_DIR"

info "Done: $RUN_DIR/report.md"
