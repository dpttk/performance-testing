#!/usr/bin/env bash
# Restore containerd to the pristine default config shipped by containerd.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

PRISTINE_BACKUP="$PERF_DIR/config/containerd.config.toml.pristine"

if [[ -f "$PRISTINE_BACKUP" ]]; then
    cp "$PRISTINE_BACKUP" "$CONTAINERD_CONFIG"
    info "Restored pristine config from $PRISTINE_BACKUP"
else
    containerd config default >"$CONTAINERD_CONFIG"
    info "Regenerated default containerd config"
fi

systemctl restart containerd
sleep 2

[[ -S "$CONTAINERD_SOCKET" ]] || error "containerd did not start after restore"

ctr_cmd namespaces create "$CONTAINERD_NAMESPACE" >/dev/null 2>&1 || true
info "containerd is running again."
