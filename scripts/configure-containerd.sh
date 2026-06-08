#!/usr/bin/env bash
# Optional: register CRI runtime handlers for Touchstone/crictl.
#
# Fallback benchmarks do NOT need this script. They pass OCI binary paths
# directly to `ctr run --runtime`.
#
# Usage:
#   sudo ./scripts/configure-containerd.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

warn "CRI handler patching is optional and mainly for Touchstone."
warn "If containerd fails to restart, run: sudo ./scripts/restore-containerd.sh"

[[ -f "$CONTAINERD_CONFIG" ]] || error "Missing $CONTAINERD_CONFIG. Run install-containerd.sh first."
[[ -x "$RUNC_STOCK_BIN" ]] || error "Missing stock runc: $RUNC_STOCK_BIN"
[[ -x "$RUNC_HARDENED_BIN" ]] || error "Missing hardened runc: $RUNC_HARDENED_BIN"
[[ -x "$RUNSC_BIN" ]] || error "Missing runsc: $RUNSC_BIN"

PRISTINE_BACKUP="$PERF_DIR/config/containerd.config.toml.pristine"
WORK_CONFIG="$(mktemp)"
trap 'rm -f "$WORK_CONFIG"' EXIT

if [[ -f "$PRISTINE_BACKUP" ]]; then
    cp "$PRISTINE_BACKUP" "$WORK_CONFIG"
else
    containerd config default >"$WORK_CONFIG"
fi

python3 - "$WORK_CONFIG" "$RUNC_STOCK_BIN" "$RUNC_HARDENED_BIN" <<'PY'
import pathlib
import re
import sys

config_path, stock_bin, hardened_bin = sys.argv[1:4]
text = pathlib.Path(config_path).read_text()
marker = "# performance-evaluation runtimes"

text = re.sub(rf"\n?{re.escape(marker)}[\s\S]*?(?=\n\[|\Z)", "", text)

plugin_prefixes = [
    "plugins.'io.containerd.cri.v1.runtime'",
    'plugins."io.containerd.cri.v1.runtime"',
    'plugins."io.containerd.grpc.v1.cri"',
]

def qprefix(prefix: str) -> str:
    return re.escape(prefix)

def patch_binary_name(body: str, prefix: str, runtime: str, binary: str) -> str:
    opt_table = rf"(\[{qprefix(prefix)}\.containerd\.runtimes\.{runtime}\.options\][\s\S]*?BinaryName\s*=\s*)\"[^\"]*\""
    if re.search(opt_table, body):
        return re.sub(opt_table, rf'\1"{binary}"', body, count=1)

    run_table = rf"(\[{qprefix(prefix)}\.containerd\.runtimes\.{runtime}\][\s\S]*?)(\n\[|\Z)"
    match = re.search(run_table, body)
    if not match:
        return body

    block = match.group(1)
    if "BinaryName" in block:
        block = re.sub(r'(BinaryName\s*=\s*)"[^"]*"', rf'\1"{binary}"', block, count=1)
    else:
        block = block.rstrip() + f'\n  BinaryName = "{binary}"\n'
    return body[: match.start(1)] + block + body[match.start(2) :]

active_prefix = next((p for p in plugin_prefixes if p in text), plugin_prefixes[0])

text = patch_binary_name(text, active_prefix, "runc", stock_bin)
text = patch_binary_name(text, active_prefix, "default_runtime", stock_bin)

extra = f"""
{marker}
[{active_prefix}.containerd.runtimes.runc-hardened]
  runtime_type = "io.containerd.runc.v2"
  [{active_prefix}.containerd.runtimes.runc-hardened.options]
    BinaryName = "{hardened_bin}"
    SystemdCgroup = true

[{active_prefix}.containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
"""
text = text.rstrip() + extra + "\n"

import tomllib
tomllib.loads(text.encode())
pathlib.Path(config_path).write_text(text)
PY

cp "$WORK_CONFIG" "$CONTAINERD_CONFIG"
systemctl restart containerd
sleep 2

if [[ ! -S "$CONTAINERD_SOCKET" ]]; then
    warn "containerd failed after CRI patching; restoring pristine config"
    "$SCRIPT_DIR/restore-containerd.sh"
    error "CRI patching failed. Fallback benchmarks work without it — skip configure-containerd.sh"
fi

ctr_cmd namespaces create "$CONTAINERD_NAMESPACE" >/dev/null 2>&1 || true
info "containerd restarted with optional CRI handlers"
