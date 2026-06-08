#!/usr/bin/env bash
# Run Touchstone benchmark suites against containerd + runc/runc-hardened/runsc.
#
# Usage:
#   sudo ./scripts/benchmark-touchstone.sh
#   sudo ./scripts/benchmark-touchstone.sh suites/performance.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

[[ -x "$TOUCHSTONE_BIN" ]] || error "Touchstone not found at $TOUCHSTONE_BIN. Run install-touchstone.sh or use benchmark-fallback.sh."

OUT_DIR="$(ensure_results_dir "touchstone-$(date +%Y%m%d-%H%M%S)")"
PATTERN="${1:-$PERF_DIR/suites/*.yaml}"

info "Touchstone output directory: $OUT_DIR"
info "Suite pattern: $PATTERN"

"$TOUCHSTONE_BIN" version || warn "Touchstone version check reported an error; continuing anyway."

"$TOUCHSTONE_BIN" benchmark -f="$PATTERN" -d "$OUT_DIR"

cp "$PERF_DIR/config.env.example" "$OUT_DIR/config.env.example" 2>/dev/null || true
if [[ -f "$PERF_DIR/config.env" ]]; then
    cp "$PERF_DIR/config.env" "$OUT_DIR/config.env"
fi

{
    echo "host=$(hostname)"
    echo "date=$(date -Iseconds)"
    echo "kernel=$(uname -r)"
    echo "runc_stock=$($RUNC_STOCK_BIN --version | head -1)"
    echo "runc_hardened=$($RUNC_HARDENED_BIN --version | head -1)"
    echo "runsc=$($RUNSC_BIN --version 2>&1 | head -1)"
} >"$OUT_DIR/host-metadata.txt"

info "Touchstone run complete. Inspect JSON and generated HTML under $OUT_DIR"
