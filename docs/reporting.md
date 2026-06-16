# Reporting

## Overhead columns

| Runtime | Baseline for overhead |
|---------|----------------------|
| `stock` | — (baseline for proposed) |
| `proposed` | `stock` |
| `docker` | — (baseline for gVisor) |
| `gvisor` | `docker` |

Positive overhead = lower throughput than baseline.

## Summary section

`report.md` includes **Proposed Runtime Enforcement Overhead** with per-workload
medians and `(1 - proposed/stock) × 100%`.

## Generation

```bash
sudo ./scripts/report.sh results/campaign-<timestamp>/
```

## Canonical results

Only full campaigns (`run.sh` without `--quick`) publish to `results/latest/`.
