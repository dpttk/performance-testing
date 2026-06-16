# Workloads

All workloads are defined in `scripts/lib/workloads.sh`. Every runtime executes
the identical shell command for a given workload identifier.

## sysbench-cpu

| Field | Value |
|-------|-------|
| Image | `docker.io/severalnines/sysbench:latest` |
| Command | `sysbench cpu --cpu-max-prime=20000 --threads=1 run` |
| Metric | `events_per_sec` (higher is better) |
| Output file | `sysbench-cpu.json` |

## sysbench-mem

| Field | Value |
|-------|-------|
| Image | `docker.io/severalnines/sysbench:latest` |
| Command | `sysbench memory --memory-total-size=2G --threads=1 run` |
| Metric | `MiB_per_sec` (higher is better) |
| Output file | `sysbench-mem.json` |

## network-iperf

| Field | Value |
|-------|-------|
| Image | `docker.io/networkstatic/iperf3:latest` |
| Command | iperf3 server (daemon) + client to `127.0.0.1` for `IPERF_DURATION` seconds |
| Metric | `Gbit_per_sec` receiver throughput (higher is better) |
| Output file | `network.json` |

Default `IPERF_DURATION=30` for full campaigns.

## redis-app

| Field | Value |
|-------|-------|
| Image | `docker.io/library/redis:7-alpine` |
| Command | `redis-server` (daemon) + `redis-benchmark` SET/GET loopback |
| Metrics | SET and GET `requests_per_sec` |
| Output files | `redis-set.json`, `redis-get.json` |

Default `REDIS_BENCH_REQUESTS=500000` for full campaigns.

## Functional verification

Functional verification requires both raw and enforced bundle runs to produce
valid, parseable workload output. Numeric throughput values may differ between
runs; equivalence is defined by successful completion under the applied policy.

## Cold-start measurement

The wall time of the first measured repetition (after warmup) is recorded in the
`cold_start_ms` field of each metric JSON file.
