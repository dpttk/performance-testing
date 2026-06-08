#!/usr/bin/env bash
# Generate a workload-specific security profile with dpttk/runc --security-scan
# and produce two runnable OCI bundles that share one rootfs:
#
#   <bundle>/raw/       pre-scan config (no generated seccomp/AppArmor; caps as-spec'd)
#   <bundle>/enforced/  post-scan config (narrowed caps + generated seccomp + AppArmor)
#
# It also records the one-time scan (profile-generation) cost and a summary of
# the generated profile (allowed syscalls, capabilities, AppArmor enforce state).
#
# Usage:
#   sudo ./scripts/security/generate-profile.sh <name> <image> [workload-cmd...]
#
# Example:
#   sudo ./scripts/security/generate-profile.sh syscalls docker.io/library/busybox:latest \
#       /bin/sh -c 'id; ls -la / >/dev/null; cat /etc/hostname >/dev/null; sleep 0.2'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/stats.sh"

require_root

NAME="${1:-}"; IMAGE="${2:-}"
[[ -n "$NAME" && -n "$IMAGE" ]] || error "Usage: $0 <name> <image> [workload-cmd...]"
shift 2 || true
WORKLOAD=("$@")
if [[ ${#WORKLOAD[@]} -eq 0 ]]; then
    # Deterministic, read-only, sleep-free loop using only the cat applet plus
    # shell builtins (faithfully covered by the scan). It counts successful
    # reads and prints RESULT=<n>; the enforcement benchmark compares this
    # output between raw and enforced to verify identical work was done.
    WORKLOAD=(/bin/sh -c 'n=0; i=0; while [ $i -lt 500 ]; do if cat /etc/passwd >/dev/null 2>&1; then n=$((n+1)); fi; i=$((i+1)); done; echo RESULT=$n')
fi

BASE="$SCAN_BUNDLES_DIR/$NAME"
info "Generating profile bundle '$NAME' from $IMAGE at $BASE"
rm -rf "$BASE"
mkdir -p "$BASE/rootfs"

# 1. Materialise rootfs from the image via docker export.
info "Exporting rootfs from $IMAGE ..."
CID="$(docker create "$IMAGE" /bin/true)"
docker export "$CID" | tar -C "$BASE/rootfs" -xf - 2>/dev/null
docker rm "$CID" >/dev/null

# 2. Generate a base OCI spec and patch the workload + non-root uid.
(
    cd "$BASE"
    runc-hardened spec >/dev/null 2>&1 || "$RUNC_HARDENED_BIN" spec
)
python3 - "$BASE/config.json" "$SCAN_UID" "$SCAN_GID" "${WORKLOAD[@]}" <<'PY'
import json, sys
cfg, uid, gid = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
args = sys.argv[4:]
c = json.load(open(cfg))
c["process"]["args"] = args
c["process"]["terminal"] = False
c["process"]["user"] = {"uid": uid, "gid": gid}
json.dump(c, open(cfg, "w"), indent=2)
print("workload:", " ".join(args))
PY

# 3. Snapshot the pre-scan (raw) config.
cp "$BASE/config.json" "$BASE/config.raw.json"

# 4. Run the scan, timing the one-time generation cost.
info "Running --security-scan (one-time profile generation)..."
SCAN_START="$(now_ms)"
SCAN_RC=0
( cd "$BASE" && "$RUNC_HARDENED_BIN" run --security-scan "scan-${NAME}-$$" ) || SCAN_RC=$?
SCAN_END="$(now_ms)"
SCAN_MS=$((SCAN_END - SCAN_START))

if [[ "$SCAN_RC" -ne 0 || ! -f "$BASE/generated/seccomp.json" ]]; then
    warn "Scan did not finalize cleanly (rc=$SCAN_RC). Seccomp may be missing if oci-seccomp-bpf-hook is absent."
fi

# 5. Build the two runnable bundles sharing one rootfs via an absolute
# root.path (runc rejects symlinked rootfs directories).
for variant in raw enforced; do
    mkdir -p "$BASE/$variant"
done
cp "$BASE/config.raw.json" "$BASE/raw/config.json"
cp "$BASE/config.json" "$BASE/enforced/config.json"
if [[ -d "$BASE/generated" ]]; then
    cp -a "$BASE/generated" "$BASE/enforced/generated"
fi
python3 - "$BASE" <<'PY'
import json, os, sys
base = sys.argv[1]
rootfs = os.path.join(base, "rootfs")
for variant in ("raw", "enforced"):
    cfgp = os.path.join(base, variant, "config.json")
    c = json.load(open(cfgp))
    c.setdefault("root", {})["path"] = rootfs
    json.dump(c, open(cfgp, "w"), indent=2)
print("root.path set to", rootfs)
PY

# 6. Summarise the generated profile.
python3 - "$BASE" "$SCAN_MS" <<'PY'
import json, os, sys
base, scan_ms = sys.argv[1], int(sys.argv[2])
gen = os.path.join(base, "generated")
summary = {"name": os.path.basename(base), "scan_ms": scan_ms}

enf = json.load(open(os.path.join(base, "enforced", "config.json")))
caps = enf.get("process", {}).get("capabilities", {})
summary["capabilities"] = {k: len(v) for k, v in caps.items()} if caps else {}

sec = enf.get("linux", {}).get("seccomp")
allowed = 0
if sec:
    for s in sec.get("syscalls", []):
        if s.get("action") in ("SCMP_ACT_ALLOW", "SCMP_ACT_LOG"):
            allowed += len(s.get("names", []))
summary["seccomp_default_action"] = sec.get("defaultAction") if sec else None
summary["seccomp_allowed_syscalls"] = allowed
summary["apparmor_profile"] = enf.get("process", {}).get("apparmorProfile")

aap = os.path.join(gen, "apparmor.profile")
summary["apparmor_enforce"] = (open(aap).read().count("flags=(complain)") == 0) if os.path.exists(aap) else None

json.dump(summary, open(os.path.join(base, "profile-summary.json"), "w"), indent=2)
print(json.dumps(summary, indent=2))
PY

info "Profile bundle ready:"
info "  raw      : $BASE/raw"
info "  enforced : $BASE/enforced"
info "  summary  : $BASE/profile-summary.json"
