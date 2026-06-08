#!/usr/bin/env bash
# Clone and build Touchstone with a modernized go.mod.
# Touchstone (2019) targets Kubernetes 1.14 APIs; this script replaces go.mod
# and exits non-zero if the build still fails on the host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root
load_go

if [[ -x "$TOUCHSTONE_BIN" ]]; then
    info "Touchstone already installed: $TOUCHSTONE_BIN"
    exit 0
fi

mkdir -p "$TOUCHSTONE_BUILD_DIR"
if [[ ! -d "$TOUCHSTONE_BUILD_DIR/.git" ]]; then
    git clone "$TOUCHSTONE_REPO" "$TOUCHSTONE_BUILD_DIR"
fi

(
    cd "$TOUCHSTONE_BUILD_DIR"
    git fetch --quiet origin "$TOUCHSTONE_REF" || true
    git checkout "$TOUCHSTONE_REF"

    cp "$PERF_DIR/patches/touchstone-go.mod" go.mod
    rm -f go.sum
    go mod tidy

    # Vendor tree pins old k8s packages; a clean module build is more portable.
    rm -rf vendor
    go build -o touchstone .
)

install -m 0755 "$TOUCHSTONE_BUILD_DIR/touchstone" "$TOUCHSTONE_BIN"
info "Touchstone installed: $($TOUCHSTONE_BIN version 2>&1 | head -1 || echo "$TOUCHSTONE_BIN")"
