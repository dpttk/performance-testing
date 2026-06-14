#!/usr/bin/env bash
# Pull container images used by the enforced-first perf pipeline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

"$SCRIPT_DIR/install-containerd.sh"

pull_one() {
    local ref="$1"
    info "Pulling $ref ..."
    ctr_cmd images pull "$ref"
}

pull_one "$BUSYBOX_IMAGE"
pull_one "$REDIS_IMAGE"

for opt in "$SYSBENCH_IMAGE" "$IPERF_IMAGE"; do
    if ctr_cmd images pull "$opt" >/dev/null 2>&1; then
        info "Pulled optional image: $opt"
    else
        warn "Could not pull $opt; the dependent metric will be skipped."
    fi
done

# Pre-pull into Docker's own image store so the 'docker' runtime's first run
# does not pay an image-pull penalty that would skew latency numbers.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    for ref in "$BUSYBOX_IMAGE" "$REDIS_IMAGE" "$SYSBENCH_IMAGE" "$IPERF_IMAGE"; do
        info "docker pull $ref ..."
        docker pull "$ref" >/dev/null 2>&1 || warn "docker pull failed: $ref"
    done
fi

info "Image pull complete."
