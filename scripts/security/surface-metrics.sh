#!/usr/bin/env bash
# Attack-surface metrics: for every runtime, launch a container and read the
# *effective* security posture from inside it (capabilities, seccomp mode,
# NoNewPrivs, AppArmor profile). This is empirical and uniform across runtimes,
# so the thesis can report "what a compromised process actually has" rather than
# relying on documentation.
#
# Also records the generated-profile syscall count for hardened_enforced from
# its profile-summary.json when available.
#
# Usage:
#   sudo ./scripts/security/surface-metrics.sh [out_dir] [scanned-bundle-name]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

OUT_DIR="${1:-$(ensure_results_dir "security-$(date +%Y%m%d-%H%M%S)")}"
SCAN_NAME="${2:-syscalls}"
mkdir -p "$OUT_DIR"
info "Surface metrics output: $OUT_DIR"

# Reads /proc/self/status + /proc/self/attr/current and prints key=value lines.
# -r so the printf \n escapes survive into the container command.
IFS= read -r PROBE <<'EOF'
printf 'CAPEFF=%s\n' "$(grep CapEff /proc/self/status | awk '{print $2}')"; printf 'CAPPRM=%s\n' "$(grep CapPrm /proc/self/status | awk '{print $2}')"; printf 'CAPBND=%s\n' "$(grep CapBnd /proc/self/status | awk '{print $2}')"; printf 'SECCOMP=%s\n' "$(grep Seccomp: /proc/self/status | awk '{print $2}')"; printf 'NONEWPRIVS=%s\n' "$(grep NoNewPrivs /proc/self/status | awk '{print $2}')"; printf 'AANAME=%s\n' "$(cat /proc/self/attr/current 2>/dev/null | tr -d '\000')"
EOF

ACTIVE=()
for alias in $RUNTIMES; do
    runtime_available "$alias" && ACTIVE+=("$alias")
done

declare -A POSTURE
for alias in "${ACTIVE[@]}"; do
    info "Reading posture: $alias"
    out="$(run_capture "$alias" "surf-${alias}-$$" "$BUSYBOX_IMAGE" sh -c "$PROBE" 2>/dev/null || true)"
    POSTURE[$alias]="$out"
done

# hardened_enforced: derive posture *statically* from the enforced config.json.
# (Running an in-container probe is unreliable here because the generated
# profile may block the probe's own tools like grep/awk.)
ENF_BASE="$SCAN_BUNDLES_DIR/$SCAN_NAME"
ENF_CONFIG=""
[[ -f "$ENF_BASE/enforced/config.json" ]] && ENF_CONFIG="$ENF_BASE/enforced/config.json"

python3 - "$OUT_DIR/surface.json" "$ENF_BASE" "$ENF_CONFIG" "${ACTIVE[@]}" <<PY
import json, sys, os

out = sys.argv[1]
enf_base = sys.argv[2]
enf_config = sys.argv[3]
aliases = sys.argv[4:]

postures = {}
$(for a in "${ACTIVE[@]}"; do
    printf 'postures["%s"] = """%s"""\n' "$a" "${POSTURE[$a]}"
done)

def parse(text):
    d = {}
    for line in text.strip().splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            d[k.strip()] = v.strip()
    caps = d.get("CAPEFF", "0") or "0"
    try:
        cap_count = bin(int(caps, 16)).count("1")
    except ValueError:
        cap_count = None
    seccomp_mode = {"0": "disabled", "1": "strict", "2": "filter"}.get(d.get("SECCOMP", "0"), d.get("SECCOMP"))
    return {
        "cap_eff_hex": d.get("CAPEFF"),
        "cap_count": cap_count,
        "cap_bnd_hex": d.get("CAPBND"),
        "seccomp_mode": seccomp_mode,
        "no_new_privs": d.get("NONEWPRIVS"),
        "apparmor_profile": d.get("AANAME") or "unconfined",
        "source": "runtime /proc/self/status",
    }

results = {a: parse(t) for a, t in postures.items()}

# hardened_enforced: static analysis of the enforced OCI config.
if enf_config and os.path.exists(enf_config):
    c = json.load(open(enf_config))
    caps = c.get("process", {}).get("capabilities", {})
    eff = caps.get("effective", []) if caps else []
    sec = c.get("linux", {}).get("seccomp")
    allowed = 0
    if sec:
        for s in sec.get("syscalls", []):
            if s.get("action") in ("SCMP_ACT_ALLOW", "SCMP_ACT_LOG"):
                allowed += len(s.get("names", []))
    results["hardened_enforced"] = {
        "cap_eff_hex": None,
        "cap_count": len(eff),
        "cap_bnd_hex": None,
        "seccomp_mode": "filter" if sec else "disabled",
        "seccomp_default_action": sec.get("defaultAction") if sec else None,
        "seccomp_allowed_syscalls": allowed if sec else None,
        "no_new_privs": "1" if c.get("process", {}).get("noNewPrivileges") else "0",
        "apparmor_profile": c.get("process", {}).get("apparmorProfile") or "unconfined",
        "source": "static analysis of enforced config.json",
    }

doc = {
    "metric": "attack_surface",
    "description": "Effective in-container security posture per runtime: capability count (popcount of CapEff), seccomp filter mode, NoNewPrivs, and AppArmor confinement. Lower capability count and active seccomp filtering mean a smaller post-compromise attack surface.",
    "results": results,
}
json.dump(doc, open(out, "w"), indent=2)
print(json.dumps(results, indent=2))
PY

info "Surface metrics complete: $OUT_DIR/surface.json"
