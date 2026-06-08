#!/usr/bin/env bash
# Performance benchmark modules. Each bench_* function takes an output directory
# and the list of active runtime aliases, runs its workload for every runtime,
# and writes a self-describing JSON file into the output directory.
#
# Sourced by benchmark-perf.sh. Relies on the runtime-runner abstraction in
# common.sh and the statistics helpers in stats.sh.

# Append "alias: <stats-json>" pairs into a metric JSON document.
# Usage: emit_metric <file> <metric> <unit> <description> <<<"$assoc_pairs"
# where assoc_pairs is lines of "alias<TAB>json".
write_metric_json() {
    local file="$1" metric="$2" unit="$3" desc="$4" pairs="$5"
    python3 - "$file" "$metric" "$unit" "$desc" <<PY
import json, sys
file, metric, unit, desc = sys.argv[1:5]
results = {}
pairs = """$pairs"""
for line in pairs.strip().splitlines():
    if not line.strip():
        continue
    alias, _, payload = line.partition("\t")
    try:
        results[alias.strip()] = json.loads(payload)
    except Exception:
        results[alias.strip()] = {"raw": payload.strip()}
doc = {"metric": metric, "unit": unit, "description": desc, "results": results}
with open(file, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
}

# ---------------------------------------------------------------------------
# 1. Startup / teardown latency
# ---------------------------------------------------------------------------
bench_latency() {
    local out="$1"; shift
    local aliases=("$@")
    local pairs=""
    info "== Latency: run+exit /bin/true, ${WARMUP} warmup + ${REPS} measured reps =="
    local alias
    for alias in "${aliases[@]}"; do
        local samples=""
        local i
        for ((i = 1; i <= WARMUP; i++)); do
            run_ephemeral "$alias" "lat-warm-${alias}-${i}-$$" "$BUSYBOX_IMAGE" /bin/true || true
        done
        for ((i = 1; i <= REPS; i++)); do
            local s e
            s="$(now_ms)"
            if run_ephemeral "$alias" "lat-${alias}-${i}-$$" "$BUSYBOX_IMAGE" /bin/true; then
                e="$(now_ms)"
                samples+="$((e - s))"$'\n'
            fi
        done
        local stats
        stats="$(echo "$samples" | stats_json)"
        info "  $alias: $stats"
        pairs+="${alias}"$'\t'"${stats}"$'\n'
    done
    write_metric_json "$out/latency.json" "startup_latency" "ms" \
        "Wall time to run and exit a busybox /bin/true container" "$pairs"
}

# ---------------------------------------------------------------------------
# 2. Density / scalability + per-container memory footprint
# ---------------------------------------------------------------------------
bench_density() {
    local out="$1"; shift
    local aliases=("$@")
    info "== Density: parallel detached containers at sizes [${DENSITY_SIZES}] =="
    local pairs=""
    local alias
    for alias in "${aliases[@]}"; do
        local per_size="{"
        local first=1
        local size
        for size in $DENSITY_SIZES; do
            local mem_before mem_after start end pids=() names=()
            mem_before="$(used_mem_mib)"
            start="$(now_ms)"
            local i
            for ((i = 1; i <= size; i++)); do
                local name="dens-${alias}-${size}-${i}-$$"
                names+=("$name")
                run_detached "$alias" "$name" "$BUSYBOX_IMAGE" sleep 60 &
                pids+=("$!")
            done
            for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
            end="$(now_ms)"
            sleep 1
            mem_after="$(used_mem_mib)"
            for name in "${names[@]}"; do stop_container "$alias" "$name"; done

            local wall=$((end - start))
            local mem_delta per_mem
            mem_delta="$(awk "BEGIN{printf \"%.1f\", $mem_after-$mem_before}")"
            per_mem="$(awk "BEGIN{printf \"%.2f\", ($mem_after-$mem_before)/$size}")"
            [[ "$first" -eq 0 ]] && per_size+=","
            first=0
            per_size+="\"$size\":{\"wall_ms\":$wall,\"mem_delta_mib\":$mem_delta,\"mem_per_container_mib\":$per_mem}"
            info "  $alias x$size: ${wall}ms, +${mem_delta}MiB (${per_mem}MiB/ctr)"
        done
        per_size+="}"
        pairs+="${alias}"$'\t'"${per_size}"$'\n'
    done
    write_metric_json "$out/density.json" "density" "mixed" \
        "Wall time and memory delta to start N parallel detached containers" "$pairs"
}

# ---------------------------------------------------------------------------
# 3. CPU + memory throughput (sysbench, in-container)
# ---------------------------------------------------------------------------
bench_cpu_mem() {
    local out="$1"; shift
    local aliases=("$@")
    if ! ctr_cmd images ls 2>/dev/null | grep -q sysbench; then
        warn "sysbench image unavailable; skipping CPU/memory throughput"
        return 0
    fi
    info "== CPU + memory throughput (sysbench, ${SYSBENCH_REPS:-5} reps) =="
    local reps="${SYSBENCH_REPS:-5}"
    local cpu_pairs="" mem_pairs=""
    local alias
    for alias in "${aliases[@]}"; do
        local cpu_s="" mem_s="" i out_txt v
        for ((i = 1; i <= reps; i++)); do
            out_txt="$(run_capture "$alias" "sb-cpu-${alias}-${i}-$$" "$SYSBENCH_IMAGE" \
                sh -c "sysbench cpu --cpu-max-prime=20000 --threads=1 run" || true)"
            v="$(echo "$out_txt" | awk '/events per second/ {gsub(/ /,"",$NF); print $NF; exit}')"
            [[ -n "$v" ]] && cpu_s+="$v"$'\n'
            out_txt="$(run_capture "$alias" "sb-mem-${alias}-${i}-$$" "$SYSBENCH_IMAGE" \
                sh -c "sysbench memory --memory-total-size=2G --threads=1 run" || true)"
            v="$(echo "$out_txt" | awk '/transferred/ {match($0,/\(([0-9.]+)/,m); if(m[1]!=""){print m[1]; exit}}')"
            [[ -n "$v" ]] && mem_s+="$v"$'\n'
        done
        local cs ms
        cs="$(echo "$cpu_s" | stats_json)"
        ms="$(echo "$mem_s" | stats_json)"
        info "  $alias cpu: $cs"
        info "  $alias mem: $ms"
        cpu_pairs+="${alias}"$'\t'"${cs}"$'\n'
        mem_pairs+="${alias}"$'\t'"${ms}"$'\n'
    done
    write_metric_json "$out/sysbench-cpu.json" "sysbench_cpu" "events_per_sec" \
        "sysbench CPU events/s (higher is better)" "$cpu_pairs"
    write_metric_json "$out/sysbench-mem.json" "sysbench_memory" "MiB_per_sec" \
        "sysbench memory transfer MiB/s (higher is better)" "$mem_pairs"
}

# ---------------------------------------------------------------------------
# 4. Disk I/O (portable, dd-based inside the container filesystem)
# ---------------------------------------------------------------------------
bench_disk() {
    local out="$1"; shift
    local aliases=("$@")
    info "== Disk I/O (in-container dd write+read, ${DISK_REPS:-5} reps) =="
    local reps="${DISK_REPS:-5}"
    local write_pairs="" read_pairs=""
    local alias
    for alias in "${aliases[@]}"; do
        local w_s="" r_s="" i out_txt v
        for ((i = 1; i <= reps; i++)); do
            out_txt="$(run_capture "$alias" "dd-${alias}-${i}-$$" "$BUSYBOX_IMAGE" sh -c \
                "dd if=/dev/zero of=/tmp/ddtest bs=1M count=512 conv=fsync 2>&1; \
                 dd if=/tmp/ddtest of=/dev/null bs=1M 2>&1; rm -f /tmp/ddtest" || true)"
            # busybox dd reports '... copied, 1.23 seconds, 414.9MB/s' (or GB/s/KB/s).
            # Normalise every throughput line to MB/s: first = write, second = read.
            local norm
            norm="$(echo "$out_txt" | grep -a 'copied' | awk '{f=$NF; u=1;
                if (f ~ /GB\/s/) u=1024; else if (f ~ /KB\/s/) u=1/1024;
                gsub(/[^0-9.]/,"",f); if (f!="") printf "%.1f\n", f*u}')"
            v="$(echo "$norm" | sed -n '1p')"; [[ -n "$v" ]] && w_s+="$v"$'\n'
            v="$(echo "$norm" | sed -n '2p')"; [[ -n "$v" ]] && r_s+="$v"$'\n'
        done
        local ws rs
        ws="$(echo "$w_s" | stats_json)"
        rs="$(echo "$r_s" | stats_json)"
        info "  $alias write: $ws"
        info "  $alias read : $rs"
        write_pairs+="${alias}"$'\t'"${ws}"$'\n'
        read_pairs+="${alias}"$'\t'"${rs}"$'\n'
    done
    write_metric_json "$out/disk-write.json" "disk_write" "MB_per_sec" \
        "Sequential write throughput via dd conv=fsync to the container filesystem (higher is better). Note: gVisor's /tmp is an internal tmpfs/gofer FS, so its write number reflects the sandbox FS layer rather than the backing block device." "$write_pairs"
    write_metric_json "$out/disk-read.json" "disk_read" "MB_per_sec" \
        "Sequential read throughput via dd (cache/FS-layer bound; reflects per-runtime filesystem access cost)" "$read_pairs"
}

# ---------------------------------------------------------------------------
# 5. Network throughput (iperf3 loopback inside one container)
# ---------------------------------------------------------------------------
bench_network() {
    local out="$1"; shift
    local aliases=("$@")
    if ! ctr_cmd images ls 2>/dev/null | grep -q iperf3; then
        warn "iperf3 image unavailable; skipping network throughput"
        return 0
    fi
    info "== Network throughput (iperf3 loopback, ${IPERF_DURATION}s) =="
    local pairs=""
    local alias
    for alias in "${aliases[@]}"; do
        local out_txt v
        out_txt="$(run_capture "$alias" "iperf-${alias}-$$" "$IPERF_IMAGE" sh -c \
            "iperf3 -s -D; sleep 1; iperf3 -c 127.0.0.1 -t $IPERF_DURATION -P $IPERF_PARALLEL -J" || true)"
        # Extract sum_received bits_per_second from the JSON blob in the output.
        v="$(echo "$out_txt" | sed -n '/{/,$p' | python3 -c \
            "import sys,json
try:
    d=json.load(sys.stdin)
    bps=d['end']['sum_received']['bits_per_second']
    print(round(bps/1e9,3))
except Exception:
    print('')" 2>/dev/null)"
        local js
        js="$(printf '%s' "$v" | stats_json)"
        info "  $alias: ${v:-n/a} Gbit/s"
        pairs+="${alias}"$'\t'"${js}"$'\n'
    done
    write_metric_json "$out/network.json" "network_throughput" "Gbit_per_sec" \
        "iperf3 loopback receiver throughput inside one container (higher is better)" "$pairs"
}

# ---------------------------------------------------------------------------
# 6. Application workload: redis-benchmark (syscall-heavy, loopback)
# ---------------------------------------------------------------------------
bench_app_redis() {
    local out="$1"; shift
    local aliases=("$@")
    if ! ctr_cmd images ls 2>/dev/null | grep -q redis; then
        warn "redis image unavailable; skipping redis-benchmark app workload"
        return 0
    fi
    info "== App: redis-benchmark SET/GET (loopback, ${REDIS_BENCH_REQUESTS} reqs) =="
    local set_pairs="" get_pairs=""
    local alias
    for alias in "${aliases[@]}"; do
        local out_txt sv gv
        out_txt="$(run_capture "$alias" "redis-${alias}-$$" "$REDIS_IMAGE" sh -c \
            "redis-server --daemonize yes --save '' --appendonly no >/dev/null 2>&1; sleep 1; \
             redis-benchmark -q -n $REDIS_BENCH_REQUESTS -c $REDIS_BENCH_CLIENTS -P $REDIS_BENCH_PIPELINE -t set,get" || true)"
        sv="$(echo "$out_txt" | tr '\r' '\n' | awk '/^SET: [0-9]/{print $2; exit}')"
        gv="$(echo "$out_txt" | tr '\r' '\n' | awk '/^GET: [0-9]/{print $2; exit}')"
        local sj gj
        sj="$(printf '%s' "$sv" | stats_json)"
        gj="$(printf '%s' "$gv" | stats_json)"
        info "  $alias SET: ${sv:-n/a} req/s  GET: ${gv:-n/a} req/s"
        set_pairs+="${alias}"$'\t'"${sj}"$'\n'
        get_pairs+="${alias}"$'\t'"${gj}"$'\n'
    done
    write_metric_json "$out/redis-set.json" "redis_set" "requests_per_sec" \
        "redis-benchmark SET throughput, server+client loopback (higher is better)" "$set_pairs"
    write_metric_json "$out/redis-get.json" "redis_get" "requests_per_sec" \
        "redis-benchmark GET throughput, server+client loopback (higher is better)" "$get_pairs"
}
