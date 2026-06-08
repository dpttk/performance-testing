#!/usr/bin/env bash
# Portable fallback benchmarks when Touchstone cannot be built or run.
#
# Measures:
#   - container startup latency (sequential /bin/true)
#   - scalability (parallel starts at 5/10/50 containers)
#   - in-container sysbench CPU and memory (when image is available)
#   - optional hardened OCI bundle startup via runc enforcement mode
#
# Usage:
#   sudo ./scripts/benchmark-fallback.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

OUT_DIR="$(ensure_results_dir "fallback-$(date +%Y%m%d-%H%M%S)")"
SUMMARY="$OUT_DIR/summary.json"

info "Fallback benchmark output: $OUT_DIR"

for alias in stock hardened gvisor; do
    smoke_test_runtime "$alias"
done

now_ms() {
    date +%s%3N
}

measure_startup() {
    local alias="$1"
    local runtime
    runtime="$(ctr_runtime "$alias")"
    local total_ms=0
    local i

    info "Startup benchmark ($alias / $runtime): $STARTUP_ITERATIONS iterations"
    for ((i = 1; i <= STARTUP_ITERATIONS; i++)); do
        local start end elapsed name
        start="$(now_ms)"
        name="startup-${alias}-${i}-$$"
        ctr_cmd run --rm --runtime "$runtime" "$BUSYBOX_IMAGE" "$name" /bin/true
        end="$(now_ms)"
        elapsed=$((end - start))
        total_ms=$((total_ms + elapsed))
    done

    awk "BEGIN {printf \"%.3f\", $total_ms / $STARTUP_ITERATIONS}"
}

measure_scalability() {
    local alias="$1"
    local count="$2"
    local runtime
    runtime="$(ctr_runtime "$alias")"
    local start end elapsed pids=()

    info "Scalability benchmark ($alias / $runtime): $count parallel containers"
    start="$(now_ms)"
    for ((i = 1; i <= count; i++)); do
        local name="scale-${alias}-${count}-${i}-$$"
        ctr_cmd run -d --runtime "$runtime" "$BUSYBOX_IMAGE" "$name" sleep 30 &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    end="$(now_ms)"
    elapsed=$((end - start))

    for ((i = 1; i <= count; i++)); do
        local name="scale-${alias}-${count}-${i}-$$"
        ctr_cmd task kill "$name" >/dev/null 2>&1 || true
        ctr_cmd task delete "$name" >/dev/null 2>&1 || true
        ctr_cmd containers delete "$name" >/dev/null 2>&1 || true
    done

    echo "$elapsed"
}

measure_sysbench() {
    local alias="$1"
    local test="$2"
    local runtime
    runtime="$(ctr_runtime "$alias")"
    local args name output metric

    case "$test" in
        cpu) args="sysbench cpu --cpu-max-prime=20000 --threads=1 run" ;;
        memory) args="sysbench memory --memory-total-size=512M --threads=1 run" ;;
        *) error "Unknown sysbench test: $test" ;;
    esac

    name="sysbench-${alias}-${test}-$$"
    if ctr_cmd images ls | grep -q sysbench; then
        output="$(ctr_cmd run --rm --runtime "$runtime" "$SYSBENCH_IMAGE" "$name" sh -c "$args" 2>&1 || true)"
    else
        warn "Sysbench image unavailable; skipping in-container $test test for $alias"
        echo "null"
        return 0
    fi

    if [[ "$test" == "cpu" ]]; then
        metric="$(echo "$output" | awk '/events per second/ {gsub(/ /,"",$NF); print $NF; exit}')"
    else
        metric="$(echo "$output" | awk '/transferred/ {gsub(/ /,"",$NF); print $NF; exit}')"
    fi

    [[ -n "$metric" ]] && echo "$metric" || echo "null"
}

measure_hardened_bundle_startup() {
    local bundle="${HARDENED_BUNDLE_DIR:-}"
    if [[ -z "$bundle" || ! -f "$bundle/config.json" ]]; then
        echo "null"
        return 0
    fi

    local total_ms=0 i start end elapsed name
    info "Hardened bundle startup (enforcement mode): $STARTUP_ITERATIONS iterations"
    for ((i = 1; i <= STARTUP_ITERATIONS; i++)); do
        name="bundle-start-$$-$i"
        start="$(now_ms)"
        "$RUNC_HARDENED_BIN" run --bundle "$bundle" -d "$name"
        end="$(now_ms)"
        "$RUNC_HARDENED_BIN" delete -f "$name" >/dev/null 2>&1 || true
        elapsed=$((end - start))
        total_ms=$((total_ms + elapsed))
    done

    awk "BEGIN {printf \"%.3f\", $total_ms / $STARTUP_ITERATIONS}"
}

declare -A STARTUP_AVG SCALE_RESULTS SYS_CPU SYS_MEM

for alias in stock hardened gvisor; do
    STARTUP_AVG[$alias]="$(measure_startup "$alias")"
done

for alias in stock hardened gvisor; do
    for size in $SCALABILITY_SIZES; do
        SCALE_RESULTS["${alias}_${size}"]="$(measure_scalability "$alias" "$size")"
    done
done

for alias in stock hardened gvisor; do
    SYS_CPU[$alias]="$(measure_sysbench "$alias" cpu)"
    SYS_MEM[$alias]="$(measure_sysbench "$alias" memory)"
done

HARDENED_BUNDLE_AVG="$(measure_hardened_bundle_startup)"

python3 - "$SUMMARY" <<PY
import json
from pathlib import Path

def num(value):
    if value in ("", "null", None):
        return None
    try:
        return float(value)
    except ValueError:
        return None

path = Path("$SUMMARY")
data = {
    "generated_at": "$(date -Iseconds)",
    "host": "$(hostname)",
    "kernel": "$(uname -r)",
    "startup_iterations": $STARTUP_ITERATIONS,
    "scalability_sizes": "$(echo "$SCALABILITY_SIZES" | tr ' ' ',')".split(","),
    "runtimes": {
        "stock": {
            "cri_handler": "$RUNTIME_STOCK",
            "ctr_runtime": "$CTR_RUNTIME_STOCK",
            "binary": "$RUNC_STOCK_BIN",
        },
        "hardened": {
            "cri_handler": "$RUNTIME_HARDENED",
            "ctr_runtime": "$CTR_RUNTIME_HARDENED",
            "binary": "$RUNC_HARDENED_BIN",
        },
        "gvisor": {
            "cri_handler": "$RUNTIME_GVISOR",
            "ctr_runtime": "$CTR_RUNTIME_GVISOR",
            "binary": "$RUNSC_BIN",
        },
    },
    "metrics": {
        "startup_ms_avg": {
            "stock": num("${STARTUP_AVG[stock]}"),
            "hardened": num("${STARTUP_AVG[hardened]}"),
            "gvisor": num("${STARTUP_AVG[gvisor]}"),
            "hardened_bundle_enforcement": num("${HARDENED_BUNDLE_AVG}"),
        },
        "scalability_ms_total": {
$(for alias in stock hardened gvisor; do
    for size in $SCALABILITY_SIZES; do
        echo "            \"${alias}_${size}\": ${SCALE_RESULTS[${alias}_${size}]},"
    done
done | sed '$ s/,$//')
        },
        "sysbench": {
            "cpu_events_per_sec": {
                "stock": num("${SYS_CPU[stock]}"),
                "hardened": num("${SYS_CPU[hardened]}"),
                "gvisor": num("${SYS_CPU[gvisor]}"),
            },
            "memory_mib_per_sec": {
                "stock": num("${SYS_MEM[stock]}"),
                "hardened": num("${SYS_MEM[hardened]}"),
                "gvisor": num("${SYS_MEM[gvisor]}"),
            },
        },
    },
}
path.write_text(json.dumps(data, indent=2) + "\n")
PY

{
    echo "host=$(hostname)"
    echo "date=$(date -Iseconds)"
    echo "runc_stock=$($RUNC_STOCK_BIN --version | head -1)"
    echo "runc_hardened=$($RUNC_HARDENED_BIN --version | head -1)"
    echo "runsc=$($RUNSC_BIN --version 2>&1 | head -1)"
} >"$OUT_DIR/host-metadata.txt"

info "Fallback benchmark complete."
info "Summary JSON: $SUMMARY"
