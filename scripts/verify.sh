#!/usr/bin/env bash
# Check that the benchmark host is ready without running full benchmarks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

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
busybox_present() { ctr_cmd images ls -q 2>/dev/null | grep -q busybox; }
check "busybox image" busybox_present || FAIL=1
check "docker engine" docker_cmd info || warn "docker not available (docker runtime + gVisor will be skipped)"

# Benchmark + scan tooling (warn-only; metrics degrade gracefully when absent).
for tool in fio iperf3 redis-benchmark python3; do
    command -v "$tool" >/dev/null 2>&1 && info "OK  tool $tool" || warn "missing tool $tool"
done
for tool in bpftool capable-bpfcc apparmor_parser; do
    command -v "$tool" >/dev/null 2>&1 && info "OK  scan tool $tool" || warn "missing scan tool $tool (--security-scan may be limited)"
done
if command -v oci-seccomp-bpf-hook >/dev/null 2>&1 || [[ -x /usr/libexec/oci/hooks.d/oci-seccomp-bpf-hook ]]; then
    info "OK  oci-seccomp-bpf-hook"
else
    warn "missing oci-seccomp-bpf-hook (seccomp profile generation disabled)"
fi

# Smoke-test every configured runtime through the runtime abstraction.
for alias in $RUNTIMES; do
    if ! runtime_available "$alias"; then
        warn "SKIP runtime '$alias' (not available on this host)"
        continue
    fi
    if run_ephemeral "$alias" "verify-${alias}-$$" "$BUSYBOX_IMAGE" /bin/true; then
        info "OK  smoke test ($alias / $(runtime_launcher "$alias"))"
    else
        warn "FAIL smoke test ($alias / $(runtime_launcher "$alias"))"
        FAIL=1
    fi
done

if [[ -x "$TOUCHSTONE_BIN" ]]; then
    info "OK  Touchstone binary ($TOUCHSTONE_BIN)"
else
    warn "Touchstone not installed (fallback benchmarks still available)"
fi

if [[ -n "${HARDENED_BUNDLE_DIR:-}" ]]; then
    if [[ -f "$HARDENED_BUNDLE_DIR/config.json" ]]; then
        info "OK  hardened bundle at $HARDENED_BUNDLE_DIR"
    else
        warn "HARDENED_BUNDLE_DIR is set but config.json is missing"
        FAIL=1
    fi
else
    warn "HARDENED_BUNDLE_DIR unset — enforcement-mode bundle benchmarks will be skipped"
fi

if [[ "$FAIL" -ne 0 ]]; then
    error "Verification failed. Run sudo ./scripts/restore-containerd.sh then sudo ./scripts/install-containerd.sh"
fi

info "Host verification passed."
