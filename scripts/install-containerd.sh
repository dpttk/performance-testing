#!/usr/bin/env bash
# Ensure containerd is installed and running with a known-good default config.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

PRISTINE_BACKUP="$PERF_DIR/config/containerd.config.toml.pristine"

# Install containerd package if absent.
if ! command -v containerd >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq containerd
fi

# Snapshot the upstream default config once so we can always roll back.
if [[ ! -f "$PRISTINE_BACKUP" ]]; then
    mkdir -p "$(dirname "$PRISTINE_BACKUP")"
    containerd config default >"$PRISTINE_BACKUP"
    info "Saved pristine containerd config to $PRISTINE_BACKUP"
fi

# Fresh installs on some distros omit /etc/containerd/ until first config write.
if [[ ! -f "$CONTAINERD_CONFIG" ]] || ! systemctl is-active --quiet containerd 2>/dev/null; then
    mkdir -p "$(dirname "$CONTAINERD_CONFIG")"
    cp "$PRISTINE_BACKUP" "$CONTAINERD_CONFIG"
    info "Installed pristine containerd config at $CONTAINERD_CONFIG"
fi

systemctl enable containerd >/dev/null 2>&1 || true
systemctl restart containerd
sleep 2

# One recovery attempt if the daemon fails to create its socket.
if [[ ! -S "$CONTAINERD_SOCKET" ]]; then
    warn "containerd did not start; resetting to pristine config"
    cp "$PRISTINE_BACKUP" "$CONTAINERD_CONFIG"
    systemctl restart containerd
    sleep 2
fi

[[ -S "$CONTAINERD_SOCKET" ]] || error "containerd socket not found at $CONTAINERD_SOCKET"

# Dedicated namespace keeps benchmark images/tasks separate from host workloads.
ctr_cmd namespaces create "$CONTAINERD_NAMESPACE" >/dev/null 2>&1 || true
info "containerd is running: $(containerd --version | head -1)"
