#!/usr/bin/env python3
"""Aggregate benchmark + security JSON in a results directory into thesis-ready
CSV, Markdown tables, and (optionally) matplotlib plots.

Usage: report.py <results_dir> [--no-plots]

The script is tolerant of missing metric files: it reports whatever is present.
"""
import json
import os
import sys
import csv

RUNTIME_ORDER = ["stock", "hardened_enforced", "gvisor", "docker"]
RUNTIME_LABEL = {
    "stock": "stock runc (ctr)",
    "hardened_enforced": "hardened enforced",
    "gvisor": "gVisor",
    "docker": "Docker default",
}

# metric file -> (title, unit, direction) ; direction: 'low' or 'high' better
SCALAR_METRICS = [
    ("latency.json", "Startup latency", "ms", "low"),
    ("sysbench-cpu.json", "CPU (sysbench)", "events/s", "high"),
    ("sysbench-mem.json", "Memory throughput (sysbench)", "MiB/s", "high"),
    ("network.json", "Network (iperf3 loopback)", "Gbit/s", "high"),
    ("redis-set.json", "redis-benchmark SET", "req/s", "high"),
    ("redis-get.json", "redis-benchmark GET", "req/s", "high"),
]


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
        if x >= 1000:
            return f"{x:,.0f}"
        return f"{x:.2f}"
    return str(x)


def main():
    if len(sys.argv) < 2:
        print("Usage: report.py <results_dir> [--no-plots]", file=sys.stderr)
        sys.exit(1)
    d = sys.argv[1]
    do_plots = "--no-plots" not in sys.argv[2:]
    md = []
    csv_rows = []

    md.append(f"# Benchmark report\n\nSource: `{d}`\n")
    meta = os.path.join(d, "host-metadata.txt")
    if os.path.exists(meta):
        md.append("## Host\n\n```\n" + open(meta).read().strip() + "\n```\n")

    # ---- Scalar performance metrics ----
    md.append("## Performance metrics\n")
    md.append("Values are medians over repeated samples; overhead is relative to `stock` "
              "(positive = slower/worse for latency, lower throughput shown as % of stock).\n")
    plot_data = {}
    for fname, title, unit, direction in SCALAR_METRICS:
        doc = load(d, fname)
        if not doc or "results" not in doc:
            continue
        res = doc["results"]
        runtimes = order_runtimes(res.keys())
        rows = []
        base = None
        sval = res.get("stock", {})
        if isinstance(sval, dict):
            base = sval.get("median")
        md.append(f"\n### {title} ({unit})\n")
        md.append("| Runtime | median | p95 | stddev | vs stock |")
        md.append("|---|---|---|---|---|")
        for r in runtimes:
            st = res.get(r, {})
            if not isinstance(st, dict):
                continue
            median = st.get("median")
            p95 = st.get("p95")
            sd = st.get("stddev")
            rel = "—"
            if base and median:
                if direction == "low":
                    rel = f"{(median/base - 1)*100:+.1f}%"
                else:
                    rel = f"{(median/base)*100:.0f}% of stock"
            md.append(f"| {RUNTIME_LABEL.get(r, r)} | {fmt(median)} | {fmt(p95)} | {fmt(sd)} | {rel} |")
            csv_rows.append([title, unit, r, fmt(median), fmt(p95), fmt(sd)])
            if median is not None:
                plot_data.setdefault(title, {})[r] = median
        md.append("")

    # ---- Enforcement overhead ----
    enf = load(d, "enforcement.json")
    if enf:
        md.append("\n## Enforcement-mode overhead\n")
        prof = enf.get("profile", {})
        md.append(f"- Workload: `{enf.get('workload')}`")
        md.append(f"- One-time scan (profile generation) cost: **{fmt(prof.get('scan_ms'))} ms**")
        md.append(f"- Generated seccomp allowed syscalls: **{prof.get('seccomp_allowed_syscalls')}**")
        md.append(f"- Functional preserved (raw == enforced output): **{enf.get('functional_preserved')}**")
        raw = enf.get("results", {}).get("raw", {})
        en = enf.get("results", {}).get("enforced", {})
        md.append(f"- raw median: {fmt(raw.get('median'))} ms; enforced median: {fmt(en.get('median'))} ms")
        md.append(f"- **Steady-state enforcement overhead: {fmt(enf.get('enforcement_overhead_pct_median'))}%**\n")

    # ---- Write CSV ----
    csv_path = os.path.join(d, "report.csv")
    with open(csv_path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["metric", "unit", "runtime", "median", "p95", "stddev"])
        w.writerows(csv_rows)

    # ---- Plots ----
    plot_files = []
    if do_plots and plot_data:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            plots_dir = os.path.join(d, "plots")
            os.makedirs(plots_dir, exist_ok=True)
            for title, series in plot_data.items():
                series = {k: v for k, v in series.items() if v is not None}
                if not series:
                    continue
                runtimes = order_runtimes(series.keys())
                vals = [series[r] for r in runtimes]
                labels = [RUNTIME_LABEL.get(r, r) for r in runtimes]
                fig, ax = plt.subplots(figsize=(7, 4))
                ax.bar(labels, vals)
                ax.set_title(title)
                ax.set_ylabel(title)
                plt.xticks(rotation=20, ha="right")
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


if __name__ == "__main__":
    main()
