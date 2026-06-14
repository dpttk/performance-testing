# Methodology Notes

## Comparison intent

Primary research target is your runtime under enforced security profiles
(`hardened_enforced`). Baselines are `stock`, `gvisor`, and `docker`.

## Mandatory profile flow

Before any benchmark numbers are accepted:

1. run synthetic workload in `--security-scan`
2. build `raw` and `enforced` bundles
3. verify functional equivalence using `RESULT=...`
4. measure overhead only when functional equivalence is true

## Performance metric policy

- startup latency: warmup + repeated samples (`WARMUP`/`REPS`)
- sysbench CPU/memory: repeated samples
- network and Redis: repeated runs through same runtime abstraction
- reporting: median, p95, p99, stddev

## Launcher asymmetry

`stock` is launched via containerd/`ctr`.
`gvisor` is launched via Docker (`runsc`) on this host due to containerd shim
stability constraints.
Interpret absolute numbers with this launcher difference in mind.

