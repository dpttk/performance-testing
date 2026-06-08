#!/usr/bin/env bash
# Install host-side benchmark tooling used by the performance suite.
#
# Most workloads run inside containers, but a few host utilities are needed for
# orchestration, statistics, and plotting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

info "Installing benchmark host packages..."
apt-get update -qq
apt-get install -y -qq \
    fio iperf3 \
    redis-tools \
    sysstat \
    jq python3 python3-pip \
    util-linux \
    bc

# matplotlib for thesis plots (optional; report degrades to tables without it).
if [[ "$GENERATE_PLOTS" == "1" ]]; then
    if ! python3 -c "import matplotlib" >/dev/null 2>&1; then
        info "Installing python3-matplotlib for report plots..."
        apt-get install -y -qq python3-matplotlib || \
            pip3 install --quiet --break-system-packages matplotlib || \
            warn "matplotlib install failed; reports will be tables-only."
    fi
fi

info "Benchmark tooling installed:"
for t in fio iperf3 redis-benchmark wrk taskset python3; do
    if command -v "$t" >/dev/null 2>&1; then
        info "  OK   $t ($(command -v "$t"))"
    else
        warn "  MISS $t (some metrics may be skipped or run in-container only)"
    fi
done
