#!/usr/bin/env bash
# Build and install containers/oci-seccomp-bpf-hook, the eBPF prestart hook that
# dpttk/runc --security-scan uses to record the syscalls a workload issues and
# emit a narrowed seccomp allow-list. Without it the scan still produces
# capability + AppArmor profiles, but no generated seccomp profile.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root
load_go

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

HOOK_BIN="${SECCOMP_HOOK_BIN:-/usr/local/bin/oci-seccomp-bpf-hook}"
HOOK_SRC="$BUILD_DIR/oci-seccomp-bpf-hook"

if [[ -x "$HOOK_BIN" ]]; then
    info "oci-seccomp-bpf-hook already installed: $HOOK_BIN"
    exit 0
fi

info "Installing build dependencies (libbpfcc-dev, libseccomp-dev)..."
apt-get update -qq
apt-get install -y -qq libbpfcc-dev libseccomp-dev pkg-config gcc make git

mkdir -p "$BUILD_DIR"
if [[ ! -d "$HOOK_SRC/.git" ]]; then
    info "Cloning containers/oci-seccomp-bpf-hook..."
    git clone --depth 1 https://github.com/containers/oci-seccomp-bpf-hook.git "$HOOK_SRC"
fi

info "Building oci-seccomp-bpf-hook..."
(
    cd "$HOOK_SRC"
    make binary || go build -o bin/oci-seccomp-bpf-hook .
)

if [[ -f "$HOOK_SRC/bin/oci-seccomp-bpf-hook" ]]; then
    install -m 0755 "$HOOK_SRC/bin/oci-seccomp-bpf-hook" "$HOOK_BIN"
    # Also place it where the scan auto-discovers it.
    mkdir -p /usr/libexec/oci/hooks.d
    install -m 0755 "$HOOK_BIN" /usr/libexec/oci/hooks.d/oci-seccomp-bpf-hook
    info "Installed: $HOOK_BIN ($("$HOOK_BIN" --version 2>&1 | head -1 || echo ok))"
else
    error "Build did not produce bin/oci-seccomp-bpf-hook; check $HOOK_SRC build output."
fi
