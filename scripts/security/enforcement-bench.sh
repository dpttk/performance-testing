#!/usr/bin/env bash
# Measure enforcement-mode performance overhead: the steady-state cost of
# running a workload under generated seccomp + AppArmor + capability profiles
# versus the same workload with no generated profiles (raw).
#
# Both variants are run via `runc-hardened run --bundle` from the bundle pair
# produced by generate-profile.sh, so the only difference is the applied
# security policy. Also reports the one-time profile-generation (scan) cost.
#
# Usage:
#   sudo ./scripts/security/enforcement-bench.sh <name> [out_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/stats.sh"
source "$SCRIPT_DIR/lib/measurement.sh"

require_root

NAME="${1:-}"
[[ -n "$NAME" ]] || error "Usage: $0 <name> [out_dir]"
BASE="$SCAN_BUNDLES_DIR/$NAME"
[[ -d "$BASE/raw" && -d "$BASE/enforced" ]] || \
    error "Bundle pair not found at $BASE. Run generate-profile.sh $NAME <image> first."

OUT_DIR="${2:-$(ensure_results_dir "enforce-$(date +%Y%m%d-%H%M%S)")}"
mkdir -p "$OUT_DIR"
info "Enforcement benchmark output: $OUT_DIR"

run_bundle_once() {
    local variant="$1" id="$2"
    "$RUNC_HARDENED_BIN" run --bundle "$BASE/$variant" "$id" >/dev/null 2>&1
    local rc=$?
    "$RUNC_HARDENED_BIN" delete -f "$id" >/dev/null 2>&1 || true
    return $rc
}

# Run a variant once and echo only the workload's RESULT= line (for functional
# equivalence checking between raw and enforced).
run_bundle_result() {
    local variant="$1" id="$2"
    "$RUNC_HARDENED_BIN" run --bundle "$BASE/$variant" "$id" 2>/dev/null | grep -a '^RESULT=' | head -1
    "$RUNC_HARDENED_BIN" delete -f "$id" >/dev/null 2>&1 || true
}

# Globals set by measure_variant: VARIANT_STATS, VARIANT_OK, VARIANT_FAIL.
measure_variant() {
    local variant="$1"
    local samples="" i s e ok=0 fail=0
    for ((i = 1; i <= WARMUP; i++)); do
        run_bundle_once "$variant" "enf-warm-${variant}-${i}-$$" || true
    done
    for ((i = 1; i <= REPS; i++)); do
        s="$(now_ms)"
        if run_bundle_once "$variant" "enf-${variant}-${i}-$$"; then
            e="$(now_ms)"
            samples+="$((e - s))"$'\n'
            ok=$((ok + 1))
        else
            e="$(now_ms)"
            samples+="$((e - s))"$'\n'
            fail=$((fail + 1))
        fi
    done
    VARIANT_OK=$ok
    VARIANT_FAIL=$fail
    VARIANT_STATS="$(echo "$samples" | stats_json)"
}

# Functional-equivalence probe: compare the workload's RESULT output across
# variants. Identical output means the enforced profile let the workload do the
# same work, so the timing delta is a valid overhead measurement.
RAW_RESULT="$(run_bundle_result raw "enf-probe-raw-$$")"
ENF_RESULT="$(run_bundle_result enforced "enf-probe-enf-$$")"
info "Functional check: raw='$RAW_RESULT' enforced='$ENF_RESULT'"
if [[ -n "$RAW_RESULT" && "$RAW_RESULT" == "$ENF_RESULT" ]]; then
    FUNC_OK=1
else
    FUNC_OK=0
    warn "Functional regression: enforced output differs from raw ('$ENF_RESULT' vs '$RAW_RESULT')."
    warn "The generated profile is incomplete for this workload; the overhead number will be marked invalid."
fi

info "== Enforcement overhead: '$NAME' raw vs enforced, ${WARMUP} warmup + ${REPS} reps =="
measure_variant raw
RAW_STATS="$VARIANT_STATS"; RAW_OK=$VARIANT_OK; RAW_FAIL=$VARIANT_FAIL
info "  raw     : $RAW_STATS (exit0=$RAW_OK fail=$RAW_FAIL)"
measure_variant enforced
ENF_STATS="$VARIANT_STATS"; ENF_OK=$VARIANT_OK; ENF_FAIL=$VARIANT_FAIL
info "  enforced: $ENF_STATS (exit0=$ENF_OK fail=$ENF_FAIL)"

SUMMARY="$BASE/profile-summary.json"
python3 - "$OUT_DIR/enforcement.json" "$NAME" "$RAW_STATS" "$ENF_STATS" "$SUMMARY" "$RAW_OK" "$RAW_FAIL" "$ENF_OK" "$ENF_FAIL" "$FUNC_OK" "$RAW_RESULT" "$ENF_RESULT" <<'PY'
import json, sys, os
out, name, raw, enf, summary_path, rok, rfail, eok, efail, func_ok, raw_res, enf_res = sys.argv[1:13]
raw_j = json.loads(raw) if raw.strip() else {}
enf_j = json.loads(enf) if enf.strip() else {}
prof = json.load(open(summary_path)) if os.path.exists(summary_path) else {}

functional_preserved = (func_ok == "1")
overhead = None
if raw_j.get("median") and enf_j.get("median") and functional_preserved:
    overhead = round((enf_j["median"] / raw_j["median"] - 1) * 100, 2)

doc = {
    "metric": "enforcement_overhead",
    "unit": "ms",
    "description": "runc-hardened bundle run latency: raw (no generated profiles) vs enforced (generated seccomp+AppArmor+caps). Overhead isolates steady-state policy-application cost; valid only when functional_preserved is true.",
    "workload": name,
    "profile": prof,
    "results": {"raw": raw_j, "enforced": enf_j},
    "exit_counts": {"raw_ok": int(rok), "raw_fail": int(rfail), "enforced_ok": int(eok), "enforced_fail": int(efail)},
    "functional_check": {"raw_output": raw_res, "enforced_output": enf_res},
    "functional_preserved": functional_preserved,
    "enforcement_overhead_pct_median": overhead,
}
json.dump(doc, open(out, "w"), indent=2)
print(json.dumps({"workload": name, "scan_ms": prof.get("scan_ms"),
                  "seccomp_allowed_syscalls": prof.get("seccomp_allowed_syscalls"),
                  "functional_preserved": functional_preserved,
                  "overhead_pct": overhead}, indent=2))
PY

info "Enforcement benchmark complete: $OUT_DIR/enforcement.json"
