# OCI Runtime Performance Evaluation

This repository measures the performance impact of enforced security profiles on a
hardened OCI runtime (`dpttk/runc`) against baseline runtimes under identical
workloads.

## Scope

| Runtime | Launcher | Security posture |
|---------|----------|------------------|
| `hardened_enforced` | `runc run --bundle` | Pre-generated seccomp, AppArmor, capabilities |
| `stock` | containerd / `ctr` | Default containerd OCI configuration |
| `gvisor` | Docker (`--runtime=runsc`) | gVisor userspace kernel defaults |
| `docker` | Docker (default) | Docker default seccomp and AppArmor |

Primary comparison subject: **`hardened_enforced`**.

## Workflow

### 1. Host preparation

```bash
cp config.env.example config.env
sudo ./scripts/setup.sh
```

### 2. Profile preparation (offline, commit artifacts)

```bash
sudo ./scripts/prepare-profiles.sh
git add profiles/
```

Security profiles are generated once per workload. The measurement pipeline does
not invoke `--security-scan`.

### 3. Measurement campaign

```bash
sudo ./scripts/run.sh
```

Full-campaign defaults: `WARMUP=10`, `REPS=50`. Development smoke:

```bash
sudo ./scripts/run.sh --quick
```

Quick runs are not published to `results/latest/`.

## Workloads

All runtimes execute the same commands:

- `sysbench-cpu` — CPU throughput
- `sysbench-mem` — memory bandwidth
- `network-iperf` — loopback TCP throughput
- `redis-app` — Redis SET/GET throughput

See [docs/workloads.md](docs/workloads.md).

## Output

Each campaign writes to `results/campaign-<timestamp>/`:

- `sysbench-cpu.json`, `sysbench-mem.json`, `network.json`
- `redis-set.json`, `redis-get.json`
- `host-metadata.txt`, `active-runtimes.txt`
- `report.md`, `report.csv`, `plots/`

Canonical results: `results/latest/` (full campaigns only).

## Documentation

- [Objectives](docs/objectives.md)
- [Methodology](docs/methodology.md)
- [Test environment](docs/test-environment.md)
- [Workloads](docs/workloads.md)
- [Security profiles](docs/security-profiles.md)
- [Reporting](docs/reporting.md)

## Repository layout

```text
profiles/           Pre-generated per-workload security profiles (committed)
scripts/
  prepare-profiles.sh Offline profile generation and verification
  run.sh              Measurement pipeline (no scanning)
  lib/
    workloads.sh      Canonical workload definitions
    bundle.sh         OCI bundle execution for hardened_enforced
    bench.sh          Benchmark implementations
results/latest/       Canonical full-campaign snapshot
```
