#!/usr/bin/env bash
# Enforced-profile lifecycle for synthetic workload:
#   generate bundle via --security-scan -> functional check -> overhead metrics

set -euo pipefail

# shellcheck source=scripts/lib/runtime.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime.sh"
# shellcheck source=scripts/lib/stats.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stats.sh"

: "${PROFILE_NAME:=synthetic}"
: "${PROFILE_IMAGE:=$BUSYBOX_IMAGE}"
: "${PROFILE_COMMAND:=n=0; i=0; while [ $i -lt 500 ]; do if cat /etc/passwd >/dev/null 2>&1; then n=$((n+1)); fi; i=$((i+1)); done; echo RESULT=$n}"

profile_generate_bundle() {
    local name="${1:-$PROFILE_NAME}"
    local image="${2:-$PROFILE_IMAGE}"
    local cmd="${3:-$PROFILE_COMMAND}"
    local base="$SCAN_BUNDLES_DIR/$name"

    info "Profile stage: generate bundle '$name' from $image"
    rm -rf "$base"
    mkdir -p "$base/rootfs"

    local cid
    cid="$(docker create "$image" /bin/true)"
    docker export "$cid" | tar -C "$base/rootfs" -xf - 2>/dev/null
    docker rm "$cid" >/dev/null

    (
        cd "$base"
        "$RUNC_HARDENED_BIN" spec >/dev/null
    )

    python3 - "$base/config.json" "$SCAN_UID" "$SCAN_GID" "$cmd" <<'PY'
import json, sys
cfg, uid, gid, cmd = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
c = json.load(open(cfg))
c["process"]["args"] = ["/bin/sh", "-c", cmd]
c["process"]["terminal"] = False
c["process"]["user"] = {"uid": uid, "gid": gid}
json.dump(c, open(cfg, "w"), indent=2)
PY

    cp "$base/config.json" "$base/config.raw.json"

    local scan_start scan_end scan_ms scan_rc=0
    scan_start="$(now_ms)"
    ( cd "$base" && "$RUNC_HARDENED_BIN" run --security-scan "scan-${name}-$$" ) || scan_rc=$?
    scan_end="$(now_ms)"
    scan_ms=$((scan_end - scan_start))
    if [[ "$scan_rc" -ne 0 ]]; then
        error "Scan failed for '$name' (rc=$scan_rc)."
    fi

    mkdir -p "$base/raw" "$base/enforced"
    cp "$base/config.raw.json" "$base/raw/config.json"
    cp "$base/config.json" "$base/enforced/config.json"
    if [[ -d "$base/generated" ]]; then
        cp -a "$base/generated" "$base/enforced/generated"
    fi

    python3 - "$base" "$scan_ms" <<'PY'
import json, os, sys
base, scan_ms = sys.argv[1], int(sys.argv[2])
rootfs = os.path.join(base, "rootfs")
for variant in ("raw", "enforced"):
    cfgp = os.path.join(base, variant, "config.json")
    c = json.load(open(cfgp))
    c.setdefault("root", {})["path"] = rootfs
    json.dump(c, open(cfgp, "w"), indent=2)

enf = json.load(open(os.path.join(base, "enforced", "config.json")))
sec = enf.get("linux", {}).get("seccomp")
allowed = 0
if sec:
    for s in sec.get("syscalls", []):
        if s.get("action") in ("SCMP_ACT_ALLOW", "SCMP_ACT_LOG"):
            allowed += len(s.get("names", []))
summary = {
    "name": os.path.basename(base),
    "scan_ms": scan_ms,
    "seccomp_default_action": sec.get("defaultAction") if sec else None,
    "seccomp_allowed_syscalls": allowed if sec else 0,
    "apparmor_profile": enf.get("process", {}).get("apparmorProfile"),
}
json.dump(summary, open(os.path.join(base, "profile-summary.json"), "w"), indent=2)
PY
}

profile_measure_enforcement() {
    local name="${1:-$PROFILE_NAME}"
    local out_dir="$2"
    local base="$SCAN_BUNDLES_DIR/$name"
    [[ -d "$base/raw" && -d "$base/enforced" ]] || error "Missing bundle pair at $base"

    run_bundle_once() {
        local variant="$1" id="$2"
        "$RUNC_HARDENED_BIN" run --bundle "$base/$variant" "$id" >/dev/null 2>&1
        local rc=$?
        "$RUNC_HARDENED_BIN" delete -f "$id" >/dev/null 2>&1 || true
        return $rc
    }

    run_bundle_result() {
        local variant="$1" id="$2"
        "$RUNC_HARDENED_BIN" run --bundle "$base/$variant" "$id" 2>/dev/null | awk '/^RESULT=/{print; exit}'
        "$RUNC_HARDENED_BIN" delete -f "$id" >/dev/null 2>&1 || true
    }

    local raw_result enf_result func_ok
    raw_result="$(run_bundle_result raw "enf-probe-raw-$$")"
    enf_result="$(run_bundle_result enforced "enf-probe-enf-$$")"
    if [[ -n "$raw_result" && "$raw_result" == "$enf_result" ]]; then
        func_ok=1
    else
        func_ok=0
        error "Functional check failed: raw='$raw_result' enforced='$enf_result'"
    fi

    measure_variant() {
        local variant="$1"
        local samples="" i s e ok=0 fail=0
        for ((i = 1; i <= WARMUP; i++)); do
            run_bundle_once "$variant" "enf-warm-${variant}-${i}-$$" || true
        done
        for ((i = 1; i <= REPS; i++)); do
            s="$(now_ms)"
            if run_bundle_once "$variant" "enf-${variant}-${i}-$$"; then
                ok=$((ok + 1))
            else
                fail=$((fail + 1))
            fi
            e="$(now_ms)"
            samples+="$((e - s))"$'\n'
        done
        VARIANT_STATS="$(echo "$samples" | stats_json)"
        VARIANT_OK="$ok"
        VARIANT_FAIL="$fail"
    }

    measure_variant raw
    local raw_stats="$VARIANT_STATS" raw_ok="$VARIANT_OK" raw_fail="$VARIANT_FAIL"
    measure_variant enforced
    local enf_stats="$VARIANT_STATS" enf_ok="$VARIANT_OK" enf_fail="$VARIANT_FAIL"

    python3 - "$out_dir/enforcement.json" "$name" "$raw_stats" "$enf_stats" \
        "$base/profile-summary.json" "$raw_ok" "$raw_fail" "$enf_ok" "$enf_fail" \
        "$func_ok" "$raw_result" "$enf_result" <<'PY'
import json, os, sys
out, name, raw, enf, summary, rok, rfail, eok, efail, f_ok, r_out, e_out = sys.argv[1:13]
raw_j = json.loads(raw) if raw.strip() else {}
enf_j = json.loads(enf) if enf.strip() else {}
profile = json.load(open(summary)) if os.path.exists(summary) else {}
functional = (f_ok == "1")
overhead = None
if functional and raw_j.get("median") and enf_j.get("median"):
    overhead = round((enf_j["median"] / raw_j["median"] - 1) * 100, 2)
doc = {
    "metric": "enforcement_overhead",
    "unit": "ms",
    "workload": name,
    "profile": profile,
    "results": {"raw": raw_j, "enforced": enf_j},
    "exit_counts": {"raw_ok": int(rok), "raw_fail": int(rfail), "enforced_ok": int(eok), "enforced_fail": int(efail)},
    "functional_check": {"raw_output": r_out, "enforced_output": e_out},
    "functional_preserved": functional,
    "enforcement_overhead_pct_median": overhead
}
json.dump(doc, open(out, "w"), indent=2)
PY
}

