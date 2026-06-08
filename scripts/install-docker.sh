#!/usr/bin/env bash
# Install Docker Engine and (optionally) register runsc + runc-hardened as
# alternative Docker runtimes for cross-checks. Docker represents the
# industry-default security posture (its own seccomp + AppArmor profiles).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if command -v docker >/dev/null 2>&1; then
    info "Docker already installed: $(docker --version)"
else
    info "Installing Docker Engine (docker.io)..."
    apt-get update -qq
    apt-get install -y -qq docker.io
fi

if [[ "$DOCKER_REGISTER_EXTRA_RUNTIMES" == "1" ]]; then
    info "Registering runsc and runc-hardened as Docker runtimes..."
    mkdir -p /etc/docker
    local_daemon=/etc/docker/daemon.json
    python3 - "$local_daemon" "$RUNSC_BIN" "$RUNC_HARDENED_BIN" <<'PY'
import json, sys, os

path, runsc, hardened = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.exists(path):
    try:
        with open(path) as fh:
            data = json.load(fh) or {}
    except Exception:
        data = {}

runtimes = data.setdefault("runtimes", {})
if os.path.exists(runsc):
    runtimes["runsc"] = {"path": runsc}
if os.path.exists(hardened):
    runtimes["runc-hardened"] = {"path": hardened}

with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
print("wrote", path)
PY
fi

systemctl enable docker >/dev/null 2>&1 || true
systemctl restart docker || systemctl start docker || true
sleep 2

if docker info >/dev/null 2>&1; then
    info "Docker is running: $(docker --version)"
    docker info --format 'Runtimes: {{range $k, $v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null || true
else
    warn "Docker installed but daemon is not responding. Check: systemctl status docker"
fi
