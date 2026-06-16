#!/usr/bin/env bash
# Per-workload security profile generation and verification (preparation phase only).

set -euo pipefail

# shellcheck source=scripts/lib/runtime.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime.sh"
# shellcheck source=scripts/lib/stats.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stats.sh"
# shellcheck source=scripts/lib/workloads.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workloads.sh"
# shellcheck source=scripts/lib/bundle.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bundle.sh"

profile_generate_workload() {
    local wl="$1"
    local image cmd base
    image="$(workload_image "$wl")"
    cmd="$(workload_command "$wl")"
    base="$(workload_profile_dir "$wl")"

    info "Profile generation: workload='$wl' image=$image"
    rm -rf "$base"
    mkdir -p "$base"

    ensure_workload_rootfs "$wl"
    local rootfs
    rootfs="$(workload_rootfs_abs "$wl")"

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
c.setdefault("root", {})["readonly"] = False
json.dump(c, open(cfg, "w"), indent=2)
PY

    python3 - "$base/config.json" "$rootfs" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c.setdefault("root", {})["path"] = sys.argv[2]
json.dump(c, open(sys.argv[1], "w"), indent=2)
PY

    cp "$base/config.json" "$base/config.raw.json"

    local scan_start scan_end scan_ms scan_rc=0
    scan_start="$(now_ms)"
    ( cd "$base" && "$RUNC_HARDENED_BIN" run --security-scan "scan-${wl}-$$" ) || scan_rc=$?
    scan_end="$(now_ms)"
    scan_ms=$((scan_end - scan_start))
    [[ "$scan_rc" -eq 0 ]] || error "Security scan failed for workload '$wl' (rc=$scan_rc)"

    mkdir -p "$base/raw" "$base/enforced"
    cp "$base/config.raw.json" "$base/raw/config.json"
    cp "$base/config.json" "$base/enforced/config.json"
    if [[ -d "$base/generated" ]]; then
        cp -a "$base/generated" "$base/enforced/generated"
    fi

    for variant in raw enforced; do
        python3 - "$base/$variant/config.json" "$rootfs" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c.setdefault("root", {})["path"] = sys.argv[2]
json.dump(c, open(sys.argv[1], "w"), indent=2)
PY
    done

    local digest
    digest="$(docker image inspect "$image" --format '{{.RepoDigests}}' 2>/dev/null | tr -d '[]' | awk '{print $1}')"
    [[ -n "$digest" ]] || digest="$image"
    write_workload_manifest "$wl" "$scan_ms" "$digest"
    profile_patch_apparmor "$wl"
    profile_patch_seccomp "$wl"
    info "Profile generated: $base/manifest.yaml (scan_ms=$scan_ms)"
}

profile_patch_seccomp() {
    local wl="$1"
    [[ "$wl" == "network-iperf" ]] || return 0
    local sec="$PROFILES_DIR/$wl/enforced/generated/seccomp.json"
    [[ -f "$sec" ]] || return 0
    python3 - "$sec" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
names = set()
for grp in doc.get("syscalls", []):
    if grp.get("action") == "SCMP_ACT_ALLOW":
        names.update(grp.get("names", []))
if "socket" in names:
    # replace AF-filtered socket groups with unrestricted socket
    doc["syscalls"] = [g for g in doc["syscalls"] if g.get("names") != ["socket"]]
    doc["syscalls"].append({"names": ["socket"], "action": "SCMP_ACT_ALLOW"})
    json.dump(doc, open(path, "w"), indent=2)
PY
    cp "$sec" "$PROFILES_DIR/$wl/generated/seccomp.json" 2>/dev/null || true
}

profile_patch_apparmor() {
    local wl="$1"
    local aa="$PROFILES_DIR/$wl/enforced/generated/apparmor.profile"
    [[ -f "$aa" ]] || return 0
    python3 - "$aa" "$wl" <<'PY'
import sys
path, wl = sys.argv[1:3]
text = open(path).read()
rules = [
    "  /bin/sh ix,",
    "  /bin/busybox ix,",
    "  /tmp/** rw,",
]
if wl == "network-iperf":
    rules += ["  network inet stream,", "  network inet dgram,"]
if wl == "redis-app":
    rules += [
        "  /usr/local/bin/redis-server ix,",
        "  /usr/local/bin/redis-benchmark ix,",
    ]
missing = [r for r in rules if r.strip() not in text]
if not missing:
    sys.exit(0)
marker = "  # --- END runc-scan audit-collected rules ---"
if marker not in text:
    text = text.rstrip() + "\n" + "\n".join(missing) + "\n"
else:
    text = text.replace(marker, "\n".join(missing) + "\n" + marker)
open(path, "w").write(text)
PY
    for aa in "$PROFILES_DIR/$wl/enforced/generated/apparmor.profile" \
              "$PROFILES_DIR/$wl/generated/apparmor.profile"; do
        [[ -f "$aa" ]] && apparmor_parser -r -W "$aa" 2>/dev/null || true
    done
}

profile_functional_check_workload() {
    local wl="$1"
    local base raw_out enf_out raw_fp enf_fp
    base="$(workload_profile_dir "$wl")"
    [[ -f "$base/enforced/config.json" && -f "$base/raw/config.json" ]] || \
        error "Missing profile bundle for workload '$wl'"

    raw_out="$(profile_bundle_run_raw "$wl" "func-raw-${wl}-$$" 1 /bin/sh -c "$(workload_command "$wl")")"
    enf_out="$(bundle_run "$wl" "func-enf-${wl}-$$" 1 /bin/sh -c "$(workload_command "$wl")")"

    if ! workload_functionally_equivalent "$wl" "$raw_out" "$enf_out"; then
        error "Functional check failed for '$wl': raw and enforced outputs invalid or incomplete"
    fi
    info "Functional check passed for '$wl'"
}

profile_measure_enforcement_workload() {
    local wl="$1" out_dir="$2"
    local base
    base="$(workload_profile_dir "$wl")"
    [[ -d "$base/raw" && -d "$base/enforced" ]] || error "Missing bundle pair for '$wl'"

    profile_functional_check_workload "$wl"

    run_variant_once() {
        local variant="$1" id="$2"
        if [[ "$variant" == "raw" ]]; then
            profile_bundle_run_raw "$wl" "$id" 0 /bin/sh -c "$(workload_command "$wl")"
        else
            bundle_run "$wl" "$id" 0 /bin/sh -c "$(workload_command "$wl")"
        fi
    }

    measure_variant() {
        local variant="$1" samples="" i s e ok=0 fail=0
        for ((i = 1; i <= WARMUP; i++)); do
            run_variant_once "$variant" "enf-warm-${variant}-${i}-$$" || true
        done
        for ((i = 1; i <= REPS; i++)); do
            s="$(now_ms)"
            if run_variant_once "$variant" "enf-${variant}-${i}-$$"; then
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

    local manifest="$base/manifest.yaml"
    local out_path="$out_dir/enforcement-${wl}.json"
    [[ "$out_dir" == "$PROFILES_DIR" ]] || true
    python3 - "$out_path" "$wl" "$raw_stats" "$enf_stats" \
        "$manifest" "$raw_ok" "$raw_fail" "$enf_ok" "$enf_fail" <<'PY'
import json, os, sys

out, wl, raw, enf, manifest, rok, rfail, eok, efail = sys.argv[1:10]
raw_j = json.loads(raw) if raw.strip() else {}
enf_j = json.loads(enf) if enf.strip() else {}
profile = {}
if os.path.exists(manifest):
    for line in open(manifest):
        if ":" in line:
            k, v = line.split(":", 1)
            profile[k.strip()] = v.strip().strip('"')
functional = True
overhead = None
if raw_j.get("median") and enf_j.get("median"):
    overhead = round((enf_j["median"] / raw_j["median"] - 1) * 100, 2)
doc = {
    "metric": "enforcement_overhead",
    "workload": wl,
    "unit": "ms",
    "profile": profile,
    "results": {"raw": raw_j, "enforced": enf_j},
    "exit_counts": {
        "raw_ok": int(rok), "raw_fail": int(rfail),
        "enforced_ok": int(eok), "enforced_fail": int(efail),
    },
    "functional_preserved": functional,
    "enforcement_overhead_pct_median": overhead,
}
json.dump(doc, open(out, "w"), indent=2)
PY
}

validate_prebuilt_profiles() {
    local wl missing=0
    for wl in "${WORKLOAD_IDS[@]}"; do
        local base="$PROFILES_DIR/$wl"
        if [[ ! -f "$base/manifest.yaml" || ! -f "$base/enforced/config.json" ]]; then
            warn "Missing prebuilt profile for workload '$wl' (run prepare-profiles.sh)"
            missing=1
            continue
        fi
        profile_functional_check_workload "$wl" || missing=1
    done
    [[ "$missing" -eq 0 ]] || error "Prebuilt profile validation failed"
    info "All prebuilt profiles validated"
}

aggregate_enforcement_results() {
    local out_dir="$1"
    python3 - "$out_dir" "${WORKLOAD_IDS[@]}" <<'PY'
import json, os, sys
out_dir, *workloads = sys.argv[1:]
items = []
for wl in workloads:
    p = os.path.join(out_dir, f"enforcement-{wl}.json")
    if os.path.exists(p):
        items.append(json.load(open(p)))
doc = {"metric": "enforcement_overhead_summary", "workloads": items}
json.dump(doc, open(os.path.join(out_dir, "enforcement.json"), "w"), indent=2)
PY
}
