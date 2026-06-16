# Methodology

## Experimental design

### Controlled variables

- Workload commands (defined in `scripts/lib/workloads.sh`)
- Sampling policy (`WARMUP`, `REPS`)
- Container images (pinned at profile preparation time)
- Host software versions (recorded in `host-metadata.txt`)

### Independent variables

- Runtime alias (`hardened_enforced`, `stock`, `gvisor`, `docker`)
- Launcher backend (bundle, containerd/ctr, Docker)

### Dependent variables

- Throughput (workload-specific units)
- Cold-start wall time (first measured repetition, milliseconds)
- Enforcement overhead (preparation phase: raw vs enforced bundle execution time)

## Phases

### Phase A — Profile preparation

Executed via `scripts/prepare-profiles.sh`:

1. Export container rootfs from the workload image.
2. Run `runc-hardened --security-scan` against the workload command.
3. Store `raw/` and `enforced/` bundle configurations under `profiles/<workload>/`.
4. Verify functional equivalence (parsed output fingerprint must match).
5. Optionally measure enforcement overhead; write `profiles/enforcement-<workload>.json`.

Artifacts under `profiles/` are committed to the repository. Rootfs trees are
exported at runtime and are not versioned.

### Phase B — Measurement

Executed via `scripts/run.sh`:

1. Verify host prerequisites and prebuilt profiles.
2. Execute each workload on every available runtime.
3. Collect `WARMUP` discarded samples followed by `REPS` measured samples.
4. Aggregate results into JSON, Markdown, CSV, and plots.

No security scanning occurs during Phase B.

## Statistical policy

| Statistic | Usage |
|-----------|-------|
| Median | Primary reported value |
| p95 | Tail latency / throughput |
| stddev | Run-to-run variance |
| Cold-start | Wall time of the first measured repetition only |

## Launcher asymmetry

| Runtime | Launcher | Rationale |
|---------|----------|-----------|
| `stock` | containerd / `ctr` | Native runc deployment path |
| `hardened_enforced` | `runc run --bundle` | Required to apply scan-generated OCI profiles |
| `gvisor`, `docker` | Docker CLI | gVisor runsc shim unstable via containerd on the reference host |

Launcher differences are recorded in `host-metadata.txt` and report tables.
Cross-launcher comparisons state this limitation explicitly.

## Limitations

- Loopback network and Redis benchmarks measure in-container stack cost, not external network I/O.
- VM hosts without cpufreq control exhibit higher run-to-run variance.
- Stock and hardened runc versions are aligned to the same upstream base ref (`RUNC_BASE_REF`) but the hardened binary includes fork-specific changes.
