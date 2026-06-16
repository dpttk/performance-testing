#!/usr/bin/env bash
# Check that the benchmark host is ready without running full benchmarks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
source "$SCRIPT_DIR/lib/runtime.sh"

require_root

check() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        info "OK  $label"
    else
        warn "FAIL $label"
        return 1
    fi
}

FAIL=0
check "stock runc binary" test -x "$RUNC_STOCK_BIN" || FAIL=1
check "hardened runc binary" test -x "$RUNC_HARDENED_BIN" || FAIL=1
check "gVisor runsc binary" test -x "$RUNSC_BIN" || FAIL=1
check "containerd socket" test -S "$CONTAINERD_SOCKET" || FAIL=1
check "containerd namespace" ctr_cmd namespaces ls || FAIL=1
check "docker engine" docker_cmd info || warn "docker not available (docker + gVisor will be skipped)"

for tool in iperf3 redis-benchmark python3; do
    command -v "$tool" >/dev/null 2>&1 && info "OK  tool $tool" || warn "missing tool $tool"
done
for tool in bpftool capable-bpfcc apparmor_parser; do
    command -v "$tool" >/dev/null 2>&1 && info "OK  scan tool $tool" || warn "missing scan tool $tool"
done
if command -v oci-seccomp-bpf-hook >/dev/null 2>&1 || [[ -x /usr/libexec/oci/hooks.d/oci-seccomp-bpf-hook ]]; then
    info "OK  oci-seccomp-bpf-hook"
else
    warn "missing oci-seccomp-bpf-hook (seccomp profile generation disabled)"
fi

for alias in $RUNTIMES; do
    if ! runtime_available "$alias"; then
        warn "SKIP runtime '$alias' (not available on this host)"
        continue
    fi
    if smoke_test_runtime "$alias"; then
        info "OK  smoke test ($alias / $(runtime_launcher "$alias"))"
    else
        warn "FAIL smoke test ($alias / $(runtime_launcher "$alias"))"
        FAIL=1
    fi
done

if [[ "$FAIL" -ne 0 ]]; then
    error "Verification failed. Run sudo ./scripts/setup.sh and sudo ./scripts/prepare-profiles.sh"
fi

info "Host verification passed."
