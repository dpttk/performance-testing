#!/usr/bin/env bash
# OCI bundle construction and execution for stock/proposed runtimes (same binary).

set -euo pipefail

[[ -n "${PERF_DIR:-}" ]] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
[[ -n "${_WORKLOADS_LOADED:-}" ]] || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workloads.sh"
_WORKLOADS_LOADED=1
# shellcheck source=scripts/lib/manifest.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manifest.sh"

# Export and cache rootfs for a workload from its pinned image reference.
ensure_workload_rootfs() {
    local wl="$1"
    local image dir
    image="$(workload_image "$wl")"
    dir="$(workload_rootfs_dir "$wl")"
    if [[ -f "$dir/.export-stamp" ]]; then
        return 0
    fi
    info "Exporting rootfs for workload '$wl' from $image"
    rm -rf "$dir"
    mkdir -p "$dir"
    local cid
    cid="$(docker create "$image" /bin/true)"
    docker export "$cid" | tar -C "$dir" -xf -
    docker rm "$cid" >/dev/null
    date -Iseconds >"$dir/.export-stamp"
}

_bundle_prepare() {
    local wl="$1" variant="$2" id="$3"; shift 3
    local args=("$@")
    local base probe src
    base="$(workload_profile_dir "$wl")"
    src="$base/$variant/config.json"
    probe="$base/runs/$id"
    [[ -f "$src" ]] || error "Missing bundle config: $src"
    ensure_workload_rootfs "$wl"

    rm -rf "$probe"
    mkdir -p "$probe"
    python3 - "$src" "$probe/config.json" "$(workload_rootfs_abs "$wl")" "${args[@]}" <<'PY'
import json, sys
src, dst, rootfs = sys.argv[1:4]
args = sys.argv[4:]
c = json.load(open(src))
c["process"]["args"] = args
c["process"]["terminal"] = False
c.setdefault("root", {})["path"] = rootfs
json.dump(c, open(dst, "w"), indent=2)
PY
    if [[ -d "$base/$variant/generated" ]]; then
        cp -a "$base/$variant/generated" "$probe/generated"
    fi
    echo "$probe"
}

_bundle_cleanup() {
    local wl="$1" id="$2" probe="$3"
    "$RUNC_PROPOSED_BIN" delete -f "$id" >/dev/null 2>&1 || true
    rm -rf "$probe"
}

# Run hardened_enforced bundle; args are process argv (e.g. /bin/sh -c "...").
bundle_run() {
    local wl="$1" id="$2" capture="$3"; shift 3
    local probe out rc
    probe="$(_bundle_prepare "$wl" enforced "$id" "$@")"
    if [[ "$capture" == "1" ]]; then
        out="$("$RUNC_PROPOSED_BIN" run --bundle "$probe" "$id" 2>&1)" || rc=$?
        echo "$out"
    else
        "$RUNC_PROPOSED_BIN" run --bundle "$probe" "$id" >/dev/null 2>&1 || rc=$?
    fi
    _bundle_cleanup "$wl" "$id" "$probe"
    return "${rc:-0}"
}

profile_bundle_run_raw() {
    local wl="$1" id="$2" capture="$3"; shift 3
    local probe out rc
    probe="$(_bundle_prepare "$wl" raw "$id" "$@")"
    if [[ "$capture" == "1" ]]; then
        out="$("$RUNC_PROPOSED_BIN" run --bundle "$probe" "$id" 2>&1)" || rc=$?
        echo "$out"
    else
        "$RUNC_PROPOSED_BIN" run --bundle "$probe" "$id" >/dev/null 2>&1 || rc=$?
    fi
    _bundle_cleanup "$wl" "$id" "$probe"
    return "${rc:-0}"
}
