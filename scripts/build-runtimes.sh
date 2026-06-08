#!/usr/bin/env bash
# Build stock upstream runc and the hardened dpttk/runc fork.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root
load_go
mkdir -p "$BUILD_DIR"

STOCK_SRC="$BUILD_DIR/runc-stock"
HARD_SRC="${HARDENED_RUNC_SRC:-$BUILD_DIR/runc-hardened}"

build_runc() {
    local src_dir="$1"
    local out_bin="$2"
    (
        cd "$src_dir"
        make BUILDTAGS="seccomp apparmor" -j"$(nproc)"
    )
    install -m 0755 "$src_dir/runc" "$out_bin"
}

if [[ -f "$RUNC_STOCK_BIN" ]]; then
    info "Stock runc already exists: $RUNC_STOCK_BIN"
else
    info "Cloning upstream runc ($RUNC_STOCK_REF)..."
    if [[ ! -d "$STOCK_SRC/.git" ]]; then
        git clone https://github.com/opencontainers/runc.git "$STOCK_SRC"
    fi
    (
        cd "$STOCK_SRC"
        git fetch --tags --quiet || true
        git checkout "$RUNC_STOCK_REF"
    )
    build_runc "$STOCK_SRC" "$RUNC_STOCK_BIN"
fi
info "Stock runtime: $($RUNC_STOCK_BIN --version | head -1)"

if [[ -f "$RUNC_HARDENED_BIN" ]]; then
    info "Hardened runc already exists: $RUNC_HARDENED_BIN"
else
    if [[ -n "${HARDENED_RUNC_SRC:-}" ]]; then
        [[ -d "$HARD_SRC" ]] || error "HARDENED_RUNC_SRC does not exist: $HARD_SRC"
        info "Building hardened runc from $HARD_SRC"
    else
        info "Cloning dpttk/runc..."
        if [[ ! -d "$HARD_SRC/.git" ]]; then
            git clone https://github.com/dpttk/runc.git "$HARD_SRC"
        fi
    fi
    build_runc "$HARD_SRC" "$RUNC_HARDENED_BIN"
fi
info "Hardened runtime: $($RUNC_HARDENED_BIN --version | head -1)"
