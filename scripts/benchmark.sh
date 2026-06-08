#!/usr/bin/env bash
# Run the full performance evaluation matrix.
#
# Usage:
#   sudo ./scripts/benchmark.sh                 # Touchstone if available, else fallback
#   sudo ./scripts/benchmark.sh --fallback-only
#   sudo ./scripts/benchmark.sh --touchstone-only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

MODE="${1:-auto}"
case "$MODE" in
    --fallback-only)
        "$SCRIPT_DIR/benchmark-fallback.sh"
        ;;
    --touchstone-only)
        "$SCRIPT_DIR/benchmark-touchstone.sh"
        ;;
    auto|"")
        if [[ -x "$TOUCHSTONE_BIN" ]]; then
            if "$SCRIPT_DIR/benchmark-touchstone.sh"; then
                info "Touchstone benchmark finished."
            else
                warn "Touchstone run failed; running fallback benchmarks."
                "$SCRIPT_DIR/benchmark-fallback.sh"
            fi
        else
            warn "Touchstone not installed; running fallback benchmarks."
            "$SCRIPT_DIR/benchmark-fallback.sh"
        fi
        ;;
    -h|--help)
        cat <<'EOF'
Usage: sudo ./scripts/benchmark.sh [--fallback-only|--touchstone-only]

Runs the benchmark matrix for:
  - stock runc (containerd handler: runc)
  - hardened dpttk/runc (containerd handler: runc-hardened)
  - gVisor (containerd handler: runsc)

Results are written under ./results/<timestamp>/.
EOF
        ;;
    *)
        error "Unknown mode: $MODE"
        ;;
esac
