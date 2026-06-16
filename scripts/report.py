#!/usr/bin/env python3
"""Aggregate benchmark JSON in a results directory into CSV, Markdown, and plots.

Usage: report.py <results_dir> [--no-plots]

Primary subject: proposed runtime (enforced profiles).
Overhead baselines: stock for proposed, docker for gVisor.
"""
import json
import os
import sys
import csv

PRIMARY = "proposed"
RUNTIME_ORDER = ["stock", "proposed", "docker", "gvisor"]
RUNTIME_LABEL = {
    "stock": "Proposed runtime (no profiles)",
    "proposed": "Proposed runtime (enforced)",
    "gvisor": "gVisor",
    "docker": "Docker default",
}
LAUNCHER = {
    "stock": "OCI bundle",
    "proposed": "OCI bundle",
    "gvisor": "Docker",
    "docker": "Docker",
}
# Runtime -> baseline alias for overhead calculation
OVERHEAD_BASELINE = {
    "proposed": "stock",
    "gvisor": "docker",
}

SCALAR_METRICS = [
    ("sysbench-cpu.json", "CPU (sysbench)", "events/s", "high"),
    ("sysbench-mem.json", "Memory (sysbench)", "MiB/s", "high"),
    ("network.json", "Network (iperf3 loopback)", "Gbit/s", "high"),
    ("redis-set.json", "Redis SET", "req/s", "high"),
    ("redis-get.json", "Redis GET", "req/s", "high"),
]

REQUIRED_RUNTIMES = set(RUNTIME_ORDER)


def load(d, name):
    p = os.path.join(d, name)
    if os.path.exists(p):
        try:
            return json.load(open(p))
        except Exception:
            return None
    return None


def order_runtimes(keys):
    keys = list(keys)
    ordered = [r for r in RUNTIME_ORDER if r in keys]
    ordered += [k for k in keys if k not in ordered]
    return ordered


def fmt(x):
    if x is None:
        return "n/a"
    if isinstance(x, float):
        if abs(x) >= 1000:
            return f"{x:,.0f}"
        return f"{x:.2f}"
    return str(x)


def overhead_pct(runtime, baseline_val, val, direction):
    """Positive overhead = worse than baseline (lower throughput or higher latency)."""
    if runtime not in OVERHEAD_BASELINE:
        return "baseline"
    if baseline_val is None or val is None or baseline_val == 0:
        return "—"
    if direction == "high":
        # throughput: proposed slower -> positive overhead
        return f"{(1 - val / baseline_val) * 100:+.2f}%"
    return f"{(val / baseline_val - 1) * 100:+.2f}%"


def validate_metrics(d):
    errors = []
    for fname, title, _, _ in SCALAR_METRICS:
        doc = load(d, fname)
        if not doc or "results" not in doc:
            continue
        present = set(doc["results"].keys())
        missing = REQUIRED_RUNTIMES - present
        if missing:
            errors.append(f"{fname}: missing runtimes {sorted(missing)}")
    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: report.py <results_dir> [--no-plots]", file=sys.stderr)
        sys.exit(1)
    d = sys.argv[1]
    do_plots = "--no-plots" not in sys.argv[2:]
    md = []
    csv_rows = []
    enforcement_rows = []

    validation_errors = validate_metrics(d)
    if validation_errors:
        md.append("## Validation warnings\n")
        for e in validation_errors:
            md.append(f"- {e}")
        md.append("")

    md.append("# Benchmark Report\n")
    md.append(f"Source: `{d}`\n")
    md.append(
        "Primary subject: **Proposed runtime (enforced)**. "
        "Enforcement overhead: proposed vs stock (same binary, same OCI bundle launcher). "
        "Sandbox overhead: gVisor vs Docker default.\n"
    )

    meta = os.path.join(d, "host-metadata.txt")
    if os.path.exists(meta):
        md.append("## Test Environment\n\n```\n" + open(meta).read().strip() + "\n```\n")

    md.append("## Performance Metrics\n")
    md.append(
        "Medians over repeated samples. "
        "**Overhead** is positive when the runtime is worse than its baseline "
        "(lower throughput). stock and docker rows are baselines.\n"
    )
    plot_data = {}
    cold_data = {}

    for fname, title, unit, direction in SCALAR_METRICS:
        doc = load(d, fname)
        if not doc or "results" not in doc:
            continue
        res = doc["results"]
        cold = doc.get("cold_start_ms", {})
        runtimes = order_runtimes(res.keys())

        md.append(f"\n### {title} ({unit})\n")
        md.append("| Runtime | Launcher | median | p95 | stddev | overhead vs baseline |")
        md.append("|---|---|---|---|---|---|")
        for r in runtimes:
            st = res.get(r, {})
            if not isinstance(st, dict):
                continue
            median = st.get("median")
            p95 = st.get("p95")
            sd = st.get("stddev")
            base_alias = OVERHEAD_BASELINE.get(r)
            base_median = None
            if base_alias:
                base_st = res.get(base_alias, {})
                if isinstance(base_st, dict):
                    base_median = base_st.get("median")
            oh = overhead_pct(r, base_median, median, direction)
            md.append(
                f"| {RUNTIME_LABEL.get(r, r)} | {LAUNCHER.get(r, 'n/a')} | "
                f"{fmt(median)} | {fmt(p95)} | {fmt(sd)} | {oh} |"
            )
            csv_rows.append([title, unit, r, LAUNCHER.get(r, ""), fmt(median), fmt(p95), fmt(sd), oh])
            if median is not None:
                plot_data.setdefault(title, {})[r] = median
            if r == PRIMARY and base_median and median:
                if direction == "high":
                    enf = round((1 - median / base_median) * 100, 2)
                else:
                    enf = round((median / base_median - 1) * 100, 2)
                enforcement_rows.append((title, enf, fmt(base_median), fmt(median)))
            cs = cold.get(r)
            if isinstance(cs, dict):
                cold_data.setdefault(title, {})[r] = cs.get("first_rep_ms", cs.get("median"))
            elif cs is not None:
                cold_data.setdefault(title, {})[r] = cs
        md.append("")

    if enforcement_rows:
        md.append("## Proposed Runtime Enforcement Overhead (proposed vs stock)\n")
        md.append("| Workload | stock median | proposed median | enforcement overhead |")
        md.append("|---|---|---|---|")
        for title, enf, stock_m, prop_m in enforcement_rows:
            md.append(f"| {title} | {stock_m} | {prop_m} | **{enf:+.2f}%** |")
        md.append("")

    if cold_data:
        md.append("## Cold-Start Wall Time (first measured rep, ms)\n")
        cols = [r for r in RUNTIME_ORDER if any(r in v for v in cold_data.values())]
        md.append("| Workload | " + " | ".join(RUNTIME_LABEL[r] for r in cols) + " |")
        md.append("|" + "---|" * (1 + len(cols)))
        for title, series in cold_data.items():
            row = [title] + [fmt(series[r]) for r in cols if r in series]
            if len(row) > 1:
                md.append("| " + " | ".join(row) + " |")
        md.append("")

    csv_path = os.path.join(d, "report.csv")
    with open(csv_path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["metric", "unit", "runtime", "launcher", "median", "p95", "stddev", "overhead_vs_baseline"])
        w.writerows(csv_rows)

    plot_files = []
    if do_plots and plot_data:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt

            plots_dir = os.path.join(d, "plots")
            os.makedirs(plots_dir, exist_ok=True)
            colors = {
                "stock": "#457b9d",
                "proposed": "#2a9d8f",
                "gvisor": "#e9c46a",
                "docker": "#e76f51",
            }
            for title, series in plot_data.items():
                series = {k: v for k, v in series.items() if v is not None}
                if not series:
                    continue
                runtimes = order_runtimes(series.keys())
                vals = [series[r] for r in runtimes]
                labels = [RUNTIME_LABEL.get(r, r) for r in runtimes]
                bar_colors = [colors.get(r, "#888888") for r in runtimes]
                fig, ax = plt.subplots(figsize=(9, 4.5))
                ax.bar(labels, vals, color=bar_colors)
                ax.set_title(title)
                ax.set_ylabel(title)
                plt.xticks(rotation=12, ha="right")
                plt.tight_layout()
                safe = "".join(c if c.isalnum() else "_" for c in title)[:40]
                fp = os.path.join(plots_dir, safe + ".png")
                fig.savefig(fp, dpi=120)
                plt.close(fig)
                plot_files.append(os.path.relpath(fp, d))
        except Exception as e:
            md.append(f"\n_Plots skipped: {e}_\n")

    if plot_files:
        md.append("\n## Plots\n")
        for fp in plot_files:
            md.append(f"![{fp}]({fp})\n")

    md_path = os.path.join(d, "report.md")
    open(md_path, "w").write("\n".join(md) + "\n")
    print(f"Wrote {md_path}")
    print(f"Wrote {csv_path}")
    if plot_files:
        print(f"Wrote {len(plot_files)} plots under {os.path.join(d, 'plots')}")
    if validation_errors:
        print("Validation warnings:", "; ".join(validation_errors), file=sys.stderr)


if __name__ == "__main__":
    main()
