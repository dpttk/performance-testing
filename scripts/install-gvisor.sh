#!/usr/bin/env bash
# Install gVisor runsc from the official release archive.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) GVISOR_ARCH=x86_64 ;;
    aarch64|arm64) GVISOR_ARCH=aarch64 ;;
    *) error "Unsupported architecture for gVisor install: $ARCH" ;;
esac

SHIM_BIN="$(dirname "$RUNSC_BIN")/containerd-shim-runsc-v1"
BASE="https://storage.googleapis.com/gvisor/releases/release/${GVISOR_RELEASE}/${ARCH}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ -x "$RUNSC_BIN" ]]; then
    info "runsc already installed: $($RUNSC_BIN --version 2>&1 | head -1)"
else
    info "Downloading gVisor runsc ${GVISOR_RELEASE} for ${ARCH}..."
    curl -fsSL "$BASE/runsc" -o "$TMP_DIR/runsc"
    install -m 0755 "$TMP_DIR/runsc" "$RUNSC_BIN"
    info "Installed: $($RUNSC_BIN --version 2>&1 | head -1)"
fi

# containerd 2.x launches gVisor through the runsc shim (io.containerd.runsc.v1)
# which must be discoverable on PATH as containerd-shim-runsc-v1.
if [[ -x "$SHIM_BIN" ]]; then
    info "containerd-shim-runsc-v1 already installed: $SHIM_BIN"
else
    info "Downloading containerd-shim-runsc-v1..."
    curl -fsSL "$BASE/containerd-shim-runsc-v1" -o "$TMP_DIR/containerd-shim-runsc-v1"
    install -m 0755 "$TMP_DIR/containerd-shim-runsc-v1" "$SHIM_BIN"
    info "Installed runsc shim: $SHIM_BIN"
fi
