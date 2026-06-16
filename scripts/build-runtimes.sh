#!/usr/bin/env bash
# Build stock upstream runc and the hardened dpttk/runc fork from aligned bases.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root
load_go
mkdir -p "$BUILD_DIR"

STOCK_SRC="$BUILD_DIR/runc-stock"
HARD_SRC="${HARDENED_RUNC_SRC:-$BUILD_DIR/runc-hardened}"

# Both binaries should track the same upstream release for fair comparison.
: "${RUNC_BASE_REF:=v1.2.5}"
: "${RUNC_STOCK_REF:=${RUNC_BASE_REF}}"
: "${HARDENED_RUNC_REF:=main}"

build_runc() {
    local src_dir="$1"
    local out_bin="$2"
    (
        cd "$src_dir"
        make BUILDTAGS="seccomp apparmor" -j"$(nproc)"
    )
    install -m 0755 "$src_dir/runc" "$out_bin"
}

rebuild_stock() {
    info "Building stock runc from opencontainers/runc @ $RUNC_STOCK_REF ..."
    if [[ ! -d "$STOCK_SRC/.git" ]]; then
        git clone https://github.com/opencontainers/runc.git "$STOCK_SRC"
    fi
    (
        cd "$STOCK_SRC"
        git fetch --tags --quiet || true
        git checkout "$RUNC_STOCK_REF"
    )
    build_runc "$STOCK_SRC" "$RUNC_STOCK_BIN"
}

rebuild_hardened() {
    if [[ -n "${HARDENED_RUNC_SRC:-}" ]]; then
        [[ -d "$HARD_SRC" ]] || error "HARDENED_RUNC_SRC does not exist: $HARD_SRC"
        info "Building hardened runc from $HARD_SRC"
    else
        info "Building hardened runc from dpttk/runc @ $HARDENED_RUNC_REF ..."
        if [[ ! -d "$HARD_SRC/.git" ]]; then
            git clone https://github.com/dpttk/runc.git "$HARD_SRC"
        fi
        (
            cd "$HARD_SRC"
            git fetch --quiet || true
            git checkout "$HARDENED_RUNC_REF"
        )
    fi
    build_runc "$HARD_SRC" "$RUNC_HARDENED_BIN"
}

if [[ "${FORCE_REBUILD_RUNTIMES:-0}" == "1" ]]; then
    rm -f "$RUNC_STOCK_BIN" "$RUNC_HARDENED_BIN"
fi

if [[ -f "$RUNC_STOCK_BIN" ]]; then
    info "Stock runc present: $RUNC_STOCK_BIN ($($RUNC_STOCK_BIN --version | head -1))"
else
    rebuild_stock
fi
info "Stock runtime: $($RUNC_STOCK_BIN --version | head -1)"

if [[ -f "$RUNC_HARDENED_BIN" ]]; then
    info "Hardened runc present: $RUNC_HARDENED_BIN ($($RUNC_HARDENED_BIN --version | head -1))"
else
    rebuild_hardened
fi
info "Hardened runtime: $($RUNC_HARDENED_BIN --version | head -1)"
