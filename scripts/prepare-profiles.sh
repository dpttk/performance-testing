#!/usr/bin/env bash
# Generate and verify per-workload security profiles (offline preparation).
#
# Usage:
#   sudo ./scripts/prepare-profiles.sh
#   sudo ./scripts/prepare-profiles.sh sysbench-cpu redis-app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/profile.sh
source "$SCRIPT_DIR/lib/profile.sh"

require_root

TARGETS=("$@")
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=("${WORKLOAD_IDS[@]}")

for wl in "${TARGETS[@]}"; do
    info "=== Preparing profile for workload: $wl ==="
    profile_generate_workload "$wl"
    profile_functional_check_workload "$wl"
    if [[ "${MEASURE_ENFORCEMENT_OVERHEAD:-1}" == "1" ]]; then
        WARMUP="${ENFORCEMENT_WARMUP:-5}" REPS="${ENFORCEMENT_REPS:-30}" \
            profile_measure_enforcement_workload "$wl" "$PROFILES_DIR"
    fi
    info "Profile ready: $PROFILES_DIR/$wl"
done

info "All requested profiles generated and functionally verified."
