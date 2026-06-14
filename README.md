# Enforced-First Runtime Benchmark Harness

This repository compares baseline OCI runtimes with your hardened runtime in
**enforced mode only** (after generated security profiles are applied).

The pipeline is intentionally short and readable:

1. verify host/runtime prerequisites
2. generate synthetic profile with `--security-scan`
3. apply profile and run functional equivalence check
4. run performance benchmarks for baseline runtimes
5. report enforcement overhead + baseline performance in one report

## Runtime matrix

- `stock` - upstream `runc` via containerd (`ctr`)
- `gvisor` - `runsc` via Docker (`docker run --runtime=runsc`)
- `docker` - Docker default runtime posture
- `hardened_enforced` - `dpttk/runc` bundle execution with generated profiles

`hardened_enforced` is measured through the mandatory scan/apply/check flow
before benchmarks.

## Benchmarks

Core performance metrics:

- startup latency (`busybox /bin/true`)
- sysbench CPU throughput
- sysbench memory throughput
- network throughput (`iperf3` loopback)
- Redis throughput (`redis-benchmark` SET/GET)

Security-profile stage:

- synthetic workload profile generation time
- functional preservation (`raw RESULT=` equals `enforced RESULT=`)
- steady-state enforcement overhead (`raw` vs `enforced`)

## Quick start

```bash
cp config.env.example config.env
sudo ./scripts/setup.sh
sudo ./scripts/run.sh
```

Quick smoke run:

```bash
sudo ./scripts/run.sh --quick
```

Run only selected metrics:

```bash
sudo ./scripts/run.sh latency cpu_mem network
```

## Output

Each run writes to `results/campaign-<timestamp>/`:

- `host-metadata.txt`
- `enforcement.json`
- `latency.json`
- `sysbench-cpu.json`
- `sysbench-mem.json`
- `network.json`
- `redis-set.json`
- `redis-get.json`
- `report.md`
- `report.csv`

Repository snapshot of the most recent agreed run is stored in `results/latest/`.

## Config highlights

Main knobs in `config.env`:

- `RUNTIMES="stock gvisor docker"` - baseline runtime set
- `WARMUP`, `REPS` - sampling policy
- `PROFILE_NAME`, `PROFILE_IMAGE`, `PROFILE_COMMAND` - synthetic scan workload
- `SCAN_UID`, `SCAN_GID`, `SCAN_BUNDLES_DIR` - scan/apply bundle controls

## Repository layout

```text
scripts/
  run.sh                 # unified enforced-first entrypoint
  setup.sh               # host preparation
  verify.sh              # prerequisite checks
  benchmark-perf.sh      # core perf runner
  report.sh              # report entrypoint
  lib/
    runtime.sh           # runtime abstraction
    profile.sh           # scan/apply/functional-check + overhead
    benchmarks.sh        # core metrics orchestration
    bench.sh             # metric implementations
    stats.sh             # median/p95/p99/stddev
    measurement.sh       # host metadata + governor pinning
```

