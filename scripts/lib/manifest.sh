#!/usr/bin/env bash
# Write manifest.yaml after profile generation (no PyYAML dependency).

write_workload_manifest() {
    local wl="$1" scan_ms="$2" digest="$3"
    local base cmd prof out
    base="$(workload_profile_dir "$wl")"
    cmd="$(workload_command "$wl")"
    prof="$base/enforced/config.json"
    out="$base/manifest.yaml"

    python3 - "$out" "$wl" "$scan_ms" "$digest" "$cmd" "$prof" <<'PY'
import json, sys

out, wl, scan_ms, digest, cmd, prof = sys.argv[1:7]
sec_allowed = 0
sec_default = None
apparmor = None
c = json.load(open(prof))
sec = c.get("linux", {}).get("seccomp")
if sec:
    sec_default = sec.get("defaultAction")
    for s in sec.get("syscalls", []):
        if s.get("action") in ("SCMP_ACT_ALLOW", "SCMP_ACT_LOG"):
            sec_allowed += len(s.get("names", []))
apparmor = c.get("process", {}).get("apparmorProfile")

def q(s):
    return '"' + str(s).replace('"', '\\"') + '"'

lines = [
    f"workload: {q(wl)}",
    f"image: {q(digest)}",
    f"command: {q(cmd)}",
    f"scan_ms: {int(scan_ms)}",
    f"seccomp_default_action: {q(sec_default)}",
    f"seccomp_allowed_syscalls: {sec_allowed}",
    f"apparmor_profile: {q(apparmor)}",
]
open(out, "w").write("\n".join(lines) + "\n")
PY
}
