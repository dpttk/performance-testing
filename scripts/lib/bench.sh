#!/usr/bin/env bash
# Performance benchmark modules. Each workload runs on every active runtime with
# identical commands. Results include throughput and cold-start wall time.

# shellcheck source=scripts/lib/workloads.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workloads.sh"
# shellcheck source=scripts/lib/bundle.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bundle.sh"

write_metric_json() {
    local file="$1" metric="$2" unit="$3" desc="$4" pairs="$5" extra="${6:-}"
    python3 - "$file" "$metric" "$unit" "$desc" "$extra" <<PY
import json, sys
file, metric, unit, desc, extra = sys.argv[1:6]
results = {}
cold_start = {}
pairs = """$pairs"""
for line in pairs.strip().splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    alias = parts[0].strip()
    if len(parts) >= 2 and parts[1].strip():
        try:
            results[alias] = json.loads(parts[1])
        except Exception:
            results[alias] = {"raw": parts[1].strip()}
    if len(parts) >= 3 and parts[2].strip():
        try:
            cold_start[alias] = json.loads(parts[2])
        except Exception:
            cold_start[alias] = {"first_rep_ms": float(parts[2])}
doc = {
    "metric": metric,
    "unit": unit,
    "description": desc,
    "results": results,
    "cold_start_ms": cold_start,
}
if extra.strip():
    try:
        doc["meta"] = json.loads(extra)
    except Exception:
        doc["meta"] = {"note": extra.strip()}
with open(file, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY
}

run_workload_capture() {
    local alias="$1" wl="$2" name="$3"
    local image cmd
    image="$(workload_image "$wl")"
    cmd="$(workload_command "$wl")"
    if [[ "$alias" == "hardened_enforced" ]]; then
        bundle_run "$wl" "$name" 1 /bin/sh -c "$cmd"
    else
        run_capture "$alias" "$name" "$image" sh -c "$cmd"
    fi
}

bench_workload() {
    local wl="$1" out="$2"; shift 2
    local aliases=("$@")
    local image cmd metric unit desc outfile
    image="$(workload_image "$wl")"
    cmd="$(workload_command "$wl")"
    metric="$(workload_metric_name "$wl")"
    unit="$(workload_unit "$wl")"
    desc="$(workload_description "$wl")"
    outfile="$out/$(workload_metric_file "$wl")"

    info "== Workload '$wl': ${WARMUP} warmup + ${REPS} measured reps =="
    local pairs="" meta set_pairs="" get_pairs=""
    meta="{\"workload\":\"$wl\",\"image\":\"$image\",\"profile\":\"$PROFILES_DIR/$wl\"}"

    local alias
    for alias in "${aliases[@]}"; do
        local samples="" cold_ms="" i out_txt v s e
        for ((i = 1; i <= WARMUP; i++)); do
            run_workload_capture "$alias" "$wl" "warm-${wl}-${alias}-${i}-$$" >/dev/null || true
        done
        for ((i = 1; i <= REPS; i++)); do
            s="$(now_ms)"
            out_txt="$(run_workload_capture "$alias" "$wl" "bench-${wl}-${alias}-${i}-$$" || true)"
            e="$(now_ms)"
            if [[ "$wl" == "redis-app" ]]; then
                v="$(workload_parse_value "$wl" "$out_txt")"
                local sv gv
                sv="${v%%	*}"
                gv="${v##*	}"
                [[ -n "$sv" ]] && samples+="set:${sv}"$'\n'
                [[ -n "$gv" ]] && samples+="get:${gv}"$'\n'
            else
                v="$(workload_parse_value "$wl" "$out_txt")"
                [[ -n "$v" ]] && samples+="$v"$'\n'
            fi
            if [[ "$i" -eq 1 ]]; then
                cold_ms="$((e - s))"
            fi
        done

        if [[ "$wl" == "redis-app" ]]; then
            local set_s get_s set_stats get_stats
            set_s="$(echo "$samples" | awk -F: '/^set:/{print $2}')"
            get_s="$(echo "$samples" | awk -F: '/^get:/{print $2}')"
            set_stats="$(echo "$set_s" | stats_json)"
            get_stats="$(echo "$get_s" | stats_json)"
            info "  $alias SET: $set_stats GET: $get_stats cold_start=${cold_ms}ms"
            set_pairs+="${alias}"$'\t'"${set_stats}"$'\t'"${cold_ms}"$'\n'
            get_pairs+="${alias}"$'\t'"${get_stats}"$'\t'"${cold_ms}"$'\n'
            continue
        fi

        local stats
        stats="$(echo "$samples" | stats_json)"
        info "  $alias: $stats cold_start=${cold_ms}ms"
        pairs+="${alias}"$'\t'"${stats}"$'\t'"${cold_ms}"$'\n'
    done

    if [[ "$wl" == "redis-app" ]]; then
        write_metric_json "$out/redis-set.json" "redis_set" "requests_per_sec" \
            "redis-benchmark SET throughput" "$set_pairs" "$meta"
        write_metric_json "$out/redis-get.json" "redis_get" "requests_per_sec" \
            "redis-benchmark GET throughput" "$get_pairs" "$meta"
    elif [[ -n "$pairs" ]]; then
        write_metric_json "$outfile" "$metric" "$unit" "$desc" "$pairs" "$meta"
    fi
}

bench_all_workloads() {
    local out="$1"; shift
    local aliases=("$@")
    local wl
    for wl in "${WORKLOAD_IDS[@]}"; do
        bench_workload "$wl" "$out" "${aliases[@]}"
    done
}
