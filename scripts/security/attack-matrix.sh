#!/usr/bin/env bash
# Post-RCE confinement matrix.
#
# Simulates what an attacker who already has command execution inside a
# container can do under each runtime/posture, by attempting a battery of
# privileged / dangerous operations and recording ALLOWED vs BLOCKED.
#
# Runtimes covered:
#   stock, hardened, gvisor, docker  -> their default posture (live containers)
#   hardened_enforced                -> a benign-generated profile applied via a
#                                       bundle, showing that a profile learned
#                                       from normal behaviour blocks post-RCE abuse
#
# Usage:
#   sudo ./scripts/security/attack-matrix.sh [out_dir] [scanned-bundle-name]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

OUT_DIR="${1:-$(ensure_results_dir "security-$(date +%Y%m%d-%H%M%S)")}"
SCAN_NAME="${2:-syscalls}"
mkdir -p "$OUT_DIR"
info "Attack matrix output: $OUT_DIR"

# The probe battery (busybox). Each probe attempts a post-exploitation action
# and prints PROBE:<name>:<ALLOWED|BLOCKED>. ALLOWED means the action succeeded
# (worse for security); BLOCKED means the runtime/profile stopped it.
IFS= read -r BATTERY <<'EOF'
rp(){ l="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PROBE:$l:ALLOWED"; else echo "PROBE:$l:BLOCKED"; fi; }; rp mount_tmpfs mount -t tmpfs none /mnt; rp umount_root umount /mnt; rp sethostname hostname rce-test; rp chroot_root chroot / /bin/true; rp mknod_device mknod /tmp/rce-dev c 1 3; rp raw_socket_ping ping -c1 -W1 127.0.0.1; rp set_system_time date -s @1700000000; rp read_kmsg dd if=/dev/kmsg bs=1 count=1; rp load_kernel_module sh -c 'modprobe dummy 2>/dev/null || insmod /lib/dummy.ko'; rp mount_proc_host mount -t proc proc /mnt; rp setuid_bit chmod u+s /bin/busybox; rp unshare_userns unshare -U /bin/true; rp ptrace_init sh -c 'cat /proc/1/environ'
EOF

PROBE_NAMES="mount_tmpfs umount_root sethostname chroot_root mknod_device raw_socket_ping set_system_time read_kmsg load_kernel_module mount_proc_host setuid_bit unshare_userns ptrace_init"

ACTIVE=()
for alias in $RUNTIMES; do
    runtime_available "$alias" && ACTIVE+=("$alias")
done

declare -A MATRIX
for alias in "${ACTIVE[@]}"; do
    info "Running attack battery: $alias"
    MATRIX[$alias]="$(run_capture "$alias" "atk-${alias}-$$" "$PROBE_IMAGE" sh -c "$BATTERY" 2>/dev/null | grep -a '^PROBE:' || true)"
done

# hardened_enforced: run the battery under the benign-generated profile.
ENF_BASE="$SCAN_BUNDLES_DIR/$SCAN_NAME"
ENF_MATRIX=""
if [[ -f "$ENF_BASE/enforced/config.json" ]]; then
    info "Running attack battery: hardened_enforced (profile '$SCAN_NAME')"
    PB="$ENF_BASE/attack-probe"
    rm -rf "$PB"; mkdir -p "$PB"
    python3 - "$ENF_BASE/enforced/config.json" "$PB/config.json" "$ENF_BASE/rootfs" "$BATTERY" <<'PY'
import json, sys
src, dst, rootfs, battery = sys.argv[1:5]
c = json.load(open(src))
c["process"]["args"] = ["/bin/sh", "-c", battery]
c["process"]["terminal"] = False
c["root"] = {"path": rootfs, "readonly": False}
json.dump(c, open(dst, "w"), indent=2)
PY
    [[ -d "$ENF_BASE/enforced/generated" ]] && cp -a "$ENF_BASE/enforced/generated" "$PB/generated"
    ENF_MATRIX="$("$RUNC_HARDENED_BIN" run --bundle "$PB" "atk-enf-$$" 2>/dev/null | grep -a '^PROBE:' || true)"
    "$RUNC_HARDENED_BIN" delete -f "atk-enf-$$" >/dev/null 2>&1 || true
fi

python3 - "$OUT_DIR/attack-matrix.json" "$PROBE_NAMES" "$ENF_MATRIX" "${ACTIVE[@]}" <<PY
import json, sys

out = sys.argv[1]
probe_names = sys.argv[2].split()
enf_matrix = sys.argv[3]
aliases = sys.argv[4:]

raw = {}
$(for a in "${ACTIVE[@]}"; do
    printf 'raw["%s"] = """%s"""\n' "$a" "${MATRIX[$a]}"
done)
if enf_matrix.strip():
    raw["hardened_enforced"] = enf_matrix

def parse(text):
    res = {}
    for line in text.strip().splitlines():
        if line.startswith("PROBE:"):
            _, name, verdict = line.split(":", 2)
            res[name] = verdict.strip()
    return res

parsed = {a: parse(t) for a, t in raw.items()}

# Fill missing probes (e.g. command absent) as UNKNOWN.
matrix = {}
allowed_counts = {}
for alias, res in parsed.items():
    row = {p: res.get(p, "UNKNOWN") for p in probe_names}
    matrix[alias] = row
    allowed_counts[alias] = sum(1 for v in row.values() if v == "ALLOWED")

doc = {
    "metric": "post_rce_confinement",
    "description": "For each runtime/posture, whether a post-compromise action succeeded (ALLOWED, worse) or was stopped (BLOCKED, better). Fewer ALLOWED probes means stronger confinement. hardened_enforced uses a profile generated from benign behaviour.",
    "probes": probe_names,
    "matrix": matrix,
    "allowed_counts": allowed_counts,
}
json.dump(doc, open(out, "w"), indent=2)

# Pretty console table.
cols = list(matrix.keys())
w = max(len(p) for p in probe_names) + 2
print("PROBE".ljust(w) + "".join(c[:10].ljust(12) for c in cols))
for p in probe_names:
    line = p.ljust(w)
    for c in cols:
        v = matrix[c][p]
        line += {"ALLOWED": "ALLOW", "BLOCKED": "block", "UNKNOWN": "?"}.get(v, v).ljust(12)
    print(line)
print("ALLOWED total".ljust(w) + "".join(str(allowed_counts[c]).ljust(12) for c in cols))
PY

info "Attack matrix complete: $OUT_DIR/attack-matrix.json"
