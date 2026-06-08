#!/usr/bin/env bash
# Aggregate a results directory into CSV + Markdown tables + plots.
#
# Usage:
#   sudo ./scripts/report.sh <results_dir> [--no-plots]
#   sudo ./scripts/report.sh            # aggregates the newest results dir

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DIR="${1:-}"
EXTRA=()
if [[ "${1:-}" == "--no-plots" ]]; then DIR=""; EXTRA+=(--no-plots); fi
[[ "${2:-}" == "--no-plots" ]] && EXTRA+=(--no-plots)

if [[ -z "$DIR" ]]; then
    DIR="$(ls -dt "$RESULTS_DIR"/*/ 2>/dev/null | head -1)"
    [[ -n "$DIR" ]] || error "No results directories under $RESULTS_DIR"
    info "Defaulting to newest results dir: $DIR"
fi
[[ -d "$DIR" ]] || error "Not a directory: $DIR"

python3 "$SCRIPT_DIR/report.py" "$DIR" "${EXTRA[@]}"
