#!/usr/bin/env bash
# Shared helpers for the performance-evaluation scripts.

set -euo pipefail

# Derive the repo root from this library's own location (scripts/lib/common.sh)
# so it is correct no matter how deeply nested the sourcing script is.
PERF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -f "$PERF_DIR/config.env" ]]; then
    # shellcheck source=/dev/null
    source "$PERF_DIR/config.env"
fi

: "${BUILD_DIR:=/tmp/performance-eval-build}"
: "${RUNC_STOCK_REF:=main}"
: "${RUNC_STOCK_BIN:=/usr/local/sbin/runc-stock}"
: "${RUNC_HARDENED_BIN:=/usr/local/sbin/runc-hardened}"
: "${CONTAINERD_CONFIG:=/etc/containerd/config.toml}"
: "${CONTAINERD_SOCKET:=/run/containerd/containerd.sock}"
: "${CONTAINERD_NAMESPACE:=performance-eval}"
: "${RUNTIME_STOCK:=runc}"
: "${RUNTIME_HARDENED:=runc-hardened}"
: "${RUNTIME_GVISOR:=runsc}"
: "${GVISOR_RELEASE:=latest}"
: "${RUNSC_BIN:=/usr/local/bin/runsc}"
: "${CTR_RUNTIME_STOCK:=$RUNC_STOCK_BIN}"
: "${CTR_RUNTIME_HARDENED:=$RUNC_HARDENED_BIN}"
: "${CTR_RUNTIME_GVISOR:=$RUNSC_BIN}"
: "${BENCHMARK_RUNS:=10}"
: "${STARTUP_ITERATIONS:=100}"
: "${RESULTS_DIR:=$PERF_DIR/results}"
: "${BUSYBOX_IMAGE:=docker.io/library/busybox:latest}"
: "${REDIS_IMAGE:=docker.io/library/redis:7-alpine}"
: "${SYSBENCH_IMAGE:=docker.io/severalnines/sysbench:latest}"
: "${IPERF_IMAGE:=docker.io/networkstatic/iperf3:latest}"
: "${GO_VERSION:=1.22.4}"

# --- Docker ---
: "${DOCKER_BIN:=/usr/bin/docker}"
: "${DOCKER_REGISTER_EXTRA_RUNTIMES:=1}"

# --- Runtime set + statistical rigor ---
: "${RUNTIMES:=stock gvisor docker hardened_enforced}"
: "${WARMUP:=10}"
: "${REPS:=50}"
: "${PIN_CPU_GOVERNOR:=1}"
: "${PIN_CPU_CORES:=}"

# --- Workload tunables ---
: "${IPERF_DURATION:=30}"
: "${IPERF_PARALLEL:=1}"
: "${REDIS_BENCH_REQUESTS:=500000}"
: "${REDIS_BENCH_CLIENTS:=50}"
: "${REDIS_BENCH_PIPELINE:=1}"

# --- Pre-generated security profiles (committed under profiles/) ---
: "${PROFILES_DIR:=$PERF_DIR/profiles}"
: "${SCAN_UID:=65532}"
: "${SCAN_GID:=65532}"
: "${GENERATE_PLOTS:=1}"

info()  { echo -e "\033[0;32m[+]\033[0m $*" >&2; }
warn()  { echo -e "\033[0;33m[!]\033[0m $*" >&2; }
error() { echo -e "\033[0;31m[x]\033[0m $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || error "Run this script as root, for example with sudo."
}

load_go() {
    if ! command -v go >/dev/null 2>&1; then
        [[ -x /usr/local/go/bin/go ]] || error "Go is not installed. Run scripts/setup.sh first."
        export PATH="$PATH:/usr/local/go/bin"
    fi
}

ensure_results_dir() {
    local stamp="${1:-manual}"
    local dir="$RESULTS_DIR/$stamp"
    mkdir -p "$dir"
    echo "$dir"
}

ctr_cmd() {
    ctr --address "$CONTAINERD_SOCKET" -n "$CONTAINERD_NAMESPACE" "$@"
}

# containerd 2.x ctr requires a shim runtime *type*, not a bare binary path.
# Stock and hardened both use the runc.v2 shim and select their binary via
# --runc-binary (see ctr_extra_args). gVisor uses runsc via Docker.
ctr_runtime() {
    case "$1" in
        stock|default|runc|hardened|runc-hardened) echo "io.containerd.runc.v2" ;;
        gvisor|runsc) echo "io.containerd.runsc.v1" ;;
        *) error "Unknown runtime alias: $1 (expected stock, hardened, or gvisor)" ;;
    esac
}

# Extra `ctr run` flags for an alias (e.g. --runc-binary to distinguish the
# stock vs hardened runc binary under the shared runc.v2 shim). Echoes a
# space-separated flag string that callers expand unquoted on purpose.
ctr_extra_args() {
    case "$1" in
        stock|default|runc) echo "--runc-binary $CTR_RUNTIME_STOCK" ;;
        hardened|runc-hardened) echo "--runc-binary $CTR_RUNTIME_HARDENED" ;;
        *) echo "" ;;
    esac
}

# CRI handler names remain useful for documentation.
runtime_handler() {
    case "$1" in
        stock|default|runc) echo "$RUNTIME_STOCK" ;;
        hardened|runc-hardened) echo "$RUNTIME_HARDENED" ;;
        gvisor|runsc) echo "$RUNTIME_GVISOR" ;;
        *) error "Unknown runtime alias: $1 (expected stock, hardened, or gvisor)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Runtime-runner abstraction
#
# Every runtime under test is addressed through a stable alias. The launch
# backend differs (containerd `ctr`, Docker CLI, or a raw runc OCI bundle), but
# benchmark modules only call the generic run_* helpers below.
#
#   stock              ctr     + runc-stock (containerd default profiles)
#   hardened           ctr     + dpttk/runc, raw (0-cap default, no profiles)
#   gvisor             docker  + runsc (userspace-kernel sandbox)
#   docker             docker  + runc (Docker default seccomp/AppArmor posture)
#   hardened_enforced  bundle  + dpttk/runc with generated profiles applied
# ---------------------------------------------------------------------------

#
# NOTE on gVisor launcher: containerd 2.2.x + the runsc v1 shim hang on this
# host (the shim stalls before the container init runs). gVisor works perfectly
# through Docker (`docker run --runtime=runsc`), so gVisor uses the Docker
# backend. This is methodologically clean: gVisor (Docker launcher) is compared
# against the `docker` default-runc runtime (same Docker launcher) to isolate
# pure sandbox cost, while `stock` vs `hardened` isolates the runc binary cost
# on the containerd-native path.
#
runtime_backend() {
    case "$1" in
        stock|hardened) echo "ctr" ;;
        docker|gvisor) echo "docker" ;;
        hardened_enforced) echo "bundle" ;;
        *) error "Unknown runtime alias: $1" ;;
    esac
}

# Extra `docker run` flags for an alias (e.g. selecting the runsc runtime).
docker_run_flags() {
    case "$1" in
        gvisor) echo "--runtime=runsc" ;;
        *) echo "" ;;
    esac
}

# True if the alias appears in the configured RUNTIMES list.
runtime_is_enabled() {
    local alias="$1" r
    for r in $RUNTIMES; do
        [[ "$r" == "$alias" ]] && return 0
    done
    return 1
}

docker_cmd() {
    "$DOCKER_BIN" "$@"
}

# Probe whether a runtime alias can actually launch a trivial container.
runtime_available() {
    local alias="$1"
    case "$(runtime_backend "$alias")" in
        ctr)
            command -v ctr >/dev/null 2>&1 || return 1
            [[ -S "$CONTAINERD_SOCKET" ]] || return 1
            ;;
        docker)
            command -v "$DOCKER_BIN" >/dev/null 2>&1 || return 1
            docker_cmd info >/dev/null 2>&1 || return 1
            # gVisor uses the Docker backend; require runsc to be registered.
            if [[ "$alias" == "gvisor" ]]; then
                docker_cmd info --format '{{range $k,$v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null | grep -qw runsc || return 1
            fi
            ;;
        bundle)
            [[ -x "$RUNC_HARDENED_BIN" ]] || return 1
            local wl
            for wl in sysbench-cpu sysbench-mem network-iperf redis-app; do
                [[ -f "$PROFILES_DIR/$wl/enforced/config.json" ]] || return 1
            done
            ;;
    esac
    return 0
}

# Run a container to completion, discard output, and clean up.
run_ephemeral() {
    local alias="$1" name="$2" image="$3"; shift 3
    case "$(runtime_backend "$alias")" in
        ctr)
            # shellcheck disable=SC2046
            ctr_cmd run --rm --runtime "$(ctr_runtime "$alias")" $(ctr_extra_args "$alias") "$image" "$name" "$@" >/dev/null 2>&1
            ;;
        docker)
            # --entrypoint "" makes the provided args the full command, matching
            # ctr semantics (where the image ENTRYPOINT is ignored).
            # shellcheck disable=SC2046
            docker_cmd run --rm $(docker_run_flags "$alias") --entrypoint "" --name "$name" "$image" "$@" >/dev/null 2>&1
            ;;
        *) error "run_ephemeral unsupported for backend of $alias" ;;
    esac
}

# Run a container to completion and echo its combined stdout/stderr.
run_capture() {
    local alias="$1" name="$2" image="$3"; shift 3
    case "$(runtime_backend "$alias")" in
        ctr)
            # shellcheck disable=SC2046
            ctr_cmd run --rm --runtime "$(ctr_runtime "$alias")" $(ctr_extra_args "$alias") "$image" "$name" "$@" 2>&1
            ;;
        docker)
            # shellcheck disable=SC2046
            docker_cmd run --rm $(docker_run_flags "$alias") --entrypoint "" --name "$name" "$image" "$@" 2>&1
            ;;
        *) error "run_capture unsupported for backend of $alias" ;;
    esac
}

# Start a detached container that keeps running until stop_container is called.
run_detached() {
    local alias="$1" name="$2" image="$3"; shift 3
    case "$(runtime_backend "$alias")" in
        ctr)
            # shellcheck disable=SC2046
            ctr_cmd run -d --runtime "$(ctr_runtime "$alias")" $(ctr_extra_args "$alias") "$image" "$name" "$@" >/dev/null 2>&1
            ;;
        docker)
            # shellcheck disable=SC2046
            docker_cmd run -d $(docker_run_flags "$alias") --entrypoint "" --name "$name" "$image" "$@" >/dev/null 2>&1
            ;;
        *) error "run_detached unsupported for backend of $alias" ;;
    esac
}

stop_container() {
    local alias="$1" name="$2"
    case "$(runtime_backend "$alias")" in
        ctr)
            ctr_cmd task kill "$name" >/dev/null 2>&1 || true
            ctr_cmd task delete "$name" >/dev/null 2>&1 || true
            ctr_cmd containers delete "$name" >/dev/null 2>&1 || true
            ;;
        docker)
            docker_cmd rm -f "$name" >/dev/null 2>&1 || true
            ;;
    esac
}

# Human-readable launcher description for a runtime alias (for reports).
runtime_launcher() {
    case "$1" in
        stock) echo "ctr+$CTR_RUNTIME_STOCK" ;;
        hardened) echo "ctr+$CTR_RUNTIME_HARDENED" ;;
        gvisor) echo "docker(--runtime=runsc)" ;;
        docker) echo "docker(default)" ;;
        hardened_enforced) echo "$RUNC_HARDENED_BIN run --bundle" ;;
        *) echo "unknown" ;;
    esac
}

smoke_test_runtime() {
    local alias="$1" wl="sysbench-cpu"
    local name="smoke-${alias}-$$"
    local image cmd out
    info "Smoke test ($alias): $(runtime_launcher "$alias") workload=$wl"
    # shellcheck source=scripts/lib/workloads.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workloads.sh"
    image="$(workload_image "$wl")"
    cmd="$(workload_command "$wl")"
    if [[ "$alias" == "hardened_enforced" ]]; then
        # shellcheck source=scripts/lib/bundle.sh
        source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bundle.sh"
        out="$(bundle_run "$wl" "$name" 1 /bin/sh -c "$cmd")"
        [[ -n "$(workload_parse_value "$wl" "$out")" ]] || return 1
    else
        out="$(run_capture "$alias" "$name" "$image" sh -c "$cmd")"
        [[ -n "$(workload_parse_value "$wl" "$out")" ]] || return 1
    fi
}

write_json_header() {
    local file="$1"
    cat >"$file" <<EOF
{
  "generated_at": "$(date -Iseconds)",
  "host": "$(hostname)",
  "kernel": "$(uname -r)",
  "runs": $BENCHMARK_RUNS
}
EOF
}
