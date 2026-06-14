#!/usr/bin/env bash
# Performance benchmark suite (core metrics).
#
# Runs the baseline runtime matrix (stock, gvisor, docker by default) and
# writes JSON metrics under results/perf-<timestamp>/.
#
# Usage:
#   sudo ./scripts/benchmark-perf.sh
#   sudo ./scripts/benchmark-perf.sh latency cpu_mem network app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/benchmarks.sh
source "$SCRIPT_DIR/lib/benchmarks.sh"

require_root

METRICS=("$@")
[[ ${#METRICS[@]} -eq 0 ]] && METRICS=(latency cpu_mem network app)

OUT_DIR="${RUN_DIR:-$(ensure_results_dir "perf-$(date +%Y%m%d-%H%M%S)")}"
mkdir -p "$OUT_DIR"
info "Performance results: $OUT_DIR"

run_perf_suite "$OUT_DIR" "${METRICS[@]}"

info "Performance suite complete: $OUT_DIR"
info "Aggregate with: sudo ./scripts/report.sh $OUT_DIR"
