#!/usr/bin/env bash
# Performance benchmark suite.
#
# Usage:
#   sudo ./scripts/benchmark-perf.sh
#   sudo ./scripts/benchmark-perf.sh sysbench-cpu network-iperf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/benchmarks.sh
source "$SCRIPT_DIR/lib/benchmarks.sh"

require_root

METRICS=("$@")
[[ ${#METRICS[@]} -eq 0 ]] && METRICS=("${WORKLOAD_IDS[@]}")

OUT_DIR="${RUN_DIR:-$(ensure_results_dir "perf-$(date +%Y%m%d-%H%M%S)")}"
mkdir -p "$OUT_DIR"
info "Performance results: $OUT_DIR"

# When invoked from run.sh, RUN_DIR is already set to the campaign directory.
run_perf_suite "$OUT_DIR" "${METRICS[@]}"

info "Performance suite complete: $OUT_DIR"
