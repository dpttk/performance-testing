# Reporting

## Artifacts

| File | Description |
|------|-------------|
| `report.md` | Human-readable tables and plot references |
| `report.csv` | Flat metric export |
| `plots/*.png` | Bar charts per metric (requires matplotlib) |
| `host-metadata.txt` | Environment and version metadata |
| `active-runtimes.txt` | Runtimes included in the campaign |

## Generation

```bash
sudo ./scripts/report.sh results/campaign-<timestamp>/
```

Invoked automatically at the end of `scripts/run.sh`.

## JSON metric schema

Each workload file contains:

```json
{
  "metric": "sysbench_cpu",
  "unit": "events_per_sec",
  "description": "...",
  "meta": { "workload": "...", "image": "...", "profile": "..." },
  "results": {
    "hardened_enforced": { "median": 0, "p95": 0, "stddev": 0 },
    "stock": { },
    "gvisor": { },
    "docker": { }
  },
  "cold_start_ms": {
    "hardened_enforced": { "first_rep_ms": 0 }
  }
}
```

## Primary comparison

Reports use `hardened_enforced` as the primary subject. The column **vs enforced**
expresses how each baseline deviates from the hardened enforced median:

- Latency-style metrics: percentage slower than enforced (positive = worse for baseline)
- Throughput metrics: percentage of enforced throughput

## Validation

`scripts/report.py` emits warnings when any metric file omits `hardened_enforced` or
other expected runtimes.

## Plots

Bar charts color-code runtimes:

| Runtime | Color |
|---------|-------|
| hardened_enforced | teal |
| stock | steel blue |
| gvisor | gold |
| docker | coral |

Disable plots: `sudo ./scripts/report.sh <dir> --no-plots`

## Canonical results

Only full campaigns (`run.sh` without `--quick`) publish to `results/latest/`.
