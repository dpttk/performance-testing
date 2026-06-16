#!/usr/bin/env bash
# Prepare a fresh benchmark host for runtime performance evaluation.
#
# Installs host dependencies, Go, containerd, gVisor, and stock/hardened runc
# binaries for the enforced-first benchmark pipeline.
#
# Usage:
#   sudo ./scripts/setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<'EOF'
Usage: sudo ./scripts/setup.sh

Installs dependencies and configures the benchmark host. Steps:
  1. Host packages (containerd, sysbench, build tools)
  2. Go toolchain
  3. Stock and hardened runc binaries
  4. gVisor (runsc)
  5. containerd (default config, no CRI patching required)
  6. Docker + scan toolchain + seccomp hook
  7. Pull benchmark container images

Copy config.env.example to config.env before running if you need non-default paths.
EOF
            exit 0
            ;;
        *) error "Unknown argument: $arg" ;;
    esac
done

require_root

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

info "Performance evaluation root: $PERF_DIR"
mkdir -p "$BUILD_DIR" "$RESULTS_DIR"

info "Installing host packages..."
apt-get update -qq
apt-get install -y -qq \
    ca-certificates curl wget jq git make gcc \
    linux-libc-dev libseccomp-dev pkg-config \
    containerd runc \
    sysbench \
    iproute2 iptables \
    python3

"$SCRIPT_DIR/install-go.sh"
"$SCRIPT_DIR/build-runtimes.sh"
"$SCRIPT_DIR/install-gvisor.sh"
"$SCRIPT_DIR/install-containerd.sh"

# New: Docker (industry-default posture + gVisor launcher), benchmark tools,
# and the --security-scan toolchain for profile generation.
"$SCRIPT_DIR/install-docker.sh"
"$SCRIPT_DIR/install-bench-tools.sh"
"$SCRIPT_DIR/install-scan-toolchain.sh"
"$SCRIPT_DIR/install-seccomp-hook.sh" || \
    warn "oci-seccomp-bpf-hook build failed; scans will produce caps+AppArmor only."

"$SCRIPT_DIR/pull-images.sh"

info ""
info "Setup complete."
info "  Stock runc     : $RUNC_STOCK_BIN"
info "  Hardened runc  : $RUNC_HARDENED_BIN"
info "  gVisor runsc   : $RUNSC_BIN"
info "  containerd     : $CONTAINERD_SOCKET"
info "  Results dir    : $RESULTS_DIR"
info ""
info "Next steps:"
info "  1. Optional: copy config.env.example to config.env and adjust paths."
info "  2. Generate profiles: sudo ./scripts/prepare-profiles.sh"
info "  3. Run measurement: sudo ./scripts/run.sh"
