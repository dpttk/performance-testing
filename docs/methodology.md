# Methodology

## Runtime definitions

| Alias | Binary | Profiles | Launcher |
|-------|--------|----------|----------|
| `stock` | Proposed (`dpttk/runc`) | None (raw bundle) | `runc run --bundle` |
| `proposed` | Proposed (`dpttk/runc`) | Enforced (seccomp, AppArmor, caps) | `runc run --bundle` |
| `docker` | System runc | Docker defaults | `docker run` |
| `gvisor` | `runsc` | gVisor defaults | `docker run --runtime=runsc` |

`stock` is **not** upstream runc. It is the proposed runtime without applied scan
profiles, executed through the same OCI bundle path as `proposed`.

## Overhead calculations

| Comparison | Baseline | Subject | What it measures |
|------------|----------|---------|------------------|
| Enforcement | `stock` | `proposed` | Steady-state cost of security profiles |
| Sandbox | `docker` | `gvisor` | gVisor sandbox cost vs industry-default Docker |

Report formula (throughput metrics):

```
enforcement_overhead % = (1 - median_proposed / median_stock) × 100
sandbox_overhead %     = (1 - median_gvisor / median_docker) × 100
```

Positive values mean the subject is slower / lower throughput than its baseline.

## Launcher consistency

Two launcher families are required:

1. **OCI bundle** — `stock` and `proposed` (profiles cannot be applied identically via Docker)
2. **Docker** — `gvisor` and `docker`

Within each pair, the launcher is identical. Cross-pair launcher differences are
documented in `host-metadata.txt` and are a known limitation.

## Phases

1. **Preparation** (`prepare-profiles.sh`) — scan, patch, verify, commit profiles
2. **Measurement** (`run.sh`) — validate profiles, benchmark, report (no scanning)

## Statistical policy

- Primary statistic: median over `REPS` samples after `WARMUP` discarded reps
- Cold-start: wall time of first measured repetition per workload

## Limitations

- Nested VM without `/dev/kvm` or cpufreq control increases variance
- Post-scan AppArmor patches (`/bin/sh`, `/tmp`, network rules) are required for some workloads
- Docker baseline includes Docker seccomp/AppArmor; it is not profile-free OCI
