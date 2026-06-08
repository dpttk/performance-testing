#!/usr/bin/env bash
# Install the host toolchain required by dpttk/runc --security-scan so this
# benchmark host can also generate the workload-specific seccomp / AppArmor /
# capability profiles used by the enforcement-mode performance tests.
#
# Mirrors the requirements documented in dpttk/runc (setup-scan-host.sh):
#   cgroup v2, bpffs (/sys/fs/bpf), bpftool, capable-bpfcc (--cgroupmap),
#   oci-seccomp-bpf-hook, and optionally AppArmor.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

info "Installing BPF + AppArmor scan toolchain..."
apt-get update -qq
apt-get install -y -qq \
    bpfcc-tools linux-tools-common "linux-tools-$(uname -r)" \
    libbpf-dev \
    apparmor apparmor-utils \
    jq || warn "Some scan packages failed to install; check kernel-tools availability."

# cgroup v2 check (scan path depends on it).
if [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]]; then
    info "OK   cgroup v2 active"
else
    warn "cgroup v2 not detected; --security-scan capability tracing may not work."
fi

# Mount bpffs if absent.
if ! mountpoint -q /sys/fs/bpf 2>/dev/null; then
    mount -t bpf bpf /sys/fs/bpf 2>/dev/null && info "Mounted bpffs at /sys/fs/bpf" || \
        warn "Could not mount bpffs at /sys/fs/bpf"
else
    info "OK   bpffs mounted at /sys/fs/bpf"
fi

# Tool presence checks.
for t in bpftool capable-bpfcc apparmor_parser; do
    if command -v "$t" >/dev/null 2>&1; then
        info "OK   $t ($(command -v "$t"))"
    else
        warn "MISS $t — scan may need it; see dpttk/runc setup-scan-host.sh"
    fi
done

# oci-seccomp-bpf-hook is installed separately (containers/oci-seccomp-bpf-hook).
if command -v oci-seccomp-bpf-hook >/dev/null 2>&1 || [[ -x /usr/libexec/oci/hooks.d/oci-seccomp-bpf-hook ]]; then
    info "OK   oci-seccomp-bpf-hook present"
else
    warn "MISS oci-seccomp-bpf-hook — install from containers/oci-seccomp-bpf-hook to enable seccomp profile generation."
    warn "     Without it, scans still produce capability + AppArmor profiles; seccomp is generated only when the hook is present."
fi

# Non-root scan user (uid/gid 65532) for complete traces.
if ! id -u "$SCAN_UID" >/dev/null 2>&1; then
    groupadd -g "$SCAN_GID" runcscan 2>/dev/null || true
    useradd -u "$SCAN_UID" -g "$SCAN_GID" -M -s /usr/sbin/nologin runcscan 2>/dev/null || \
        warn "Could not create runcscan user (uid $SCAN_UID); scans may run as root with less complete traces."
    [[ -n "$(id -un "$SCAN_UID" 2>/dev/null)" ]] && info "Created scan user runcscan (uid $SCAN_UID)"
else
    info "OK   scan uid $SCAN_UID already exists ($(id -un "$SCAN_UID"))"
fi

info "Scan toolchain setup complete."
