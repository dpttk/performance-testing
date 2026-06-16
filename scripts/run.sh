#!/usr/bin/env bash
# Measurement pipeline (no security scanning during this phase):
#   verify -> validate prebuilt profiles -> performance benchmarks -> report

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
        sysbench-cpu|sysbench-mem|network-iperf|redis-app) METRICS+=("$arg") ;;
        -h|--help)
            cat <<'EOF'
Usage: sudo ./scripts/run.sh [--quick] [sysbench-cpu sysbench-mem network-iperf redis-app]

Measurement campaign (profiles must exist under profiles/):
  1) verify host/runtime prerequisites
  2) validate prebuilt profiles (functional check per workload)
  3) performance benchmarks (all runtimes, identical workloads)
  4) aggregate Markdown + CSV report + plots

Generate profiles first:
  sudo ./scripts/prepare-profiles.sh
EOF
            exit 0
            ;;
        *) error "Unknown argument: $arg" ;;
    esac
done

if [[ "$QUICK" -eq 1 ]]; then
    export REPS=8 WARMUP=2 IPERF_DURATION=4 REDIS_BENCH_REQUESTS=30000
    info "Quick mode enabled (results will not be published to results/latest/)."
fi

RUN_DIR="$(ensure_results_dir "campaign-$(date +%Y%m%d-%H%M%S)")"
export RUN_DIR
mkdir -p "$RUN_DIR"

info "=== [1/4] Verify host prerequisites ==="
"$SCRIPT_DIR/verify.sh"

info "=== [2/4] Validate prebuilt profiles ==="
validate_prebuilt_profiles

info "=== [3/4] Performance benchmarks ==="
if [[ ${#METRICS[@]} -eq 0 ]]; then
    "$SCRIPT_DIR/benchmark-perf.sh"
else
    "$SCRIPT_DIR/benchmark-perf.sh" "${METRICS[@]}"
fi

info "=== [4/4] Aggregate report ==="
"$SCRIPT_DIR/report.sh" "$RUN_DIR"

cp "$PERF_DIR/config.env" "$RUN_DIR/config.env.used" 2>/dev/null || true

if [[ "$QUICK" -eq 0 ]]; then
    LATEST_DIR="$PERF_DIR/results/latest"
    mkdir -p "$LATEST_DIR"
    rsync -a --delete "$RUN_DIR/" "$LATEST_DIR/" 2>/dev/null || {
        rm -rf "$LATEST_DIR"
        mkdir -p "$LATEST_DIR"
        cp -a "$RUN_DIR/." "$LATEST_DIR/"
    }
    info "Published snapshot: $LATEST_DIR"
else
    info "Quick run complete (not published to results/latest/): $RUN_DIR"
fi

info "Done: $RUN_DIR/report.md"
