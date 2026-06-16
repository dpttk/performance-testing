#!/usr/bin/env python3
"""Aggregate benchmark JSON in a results directory into CSV, Markdown, and plots.

Usage: report.py <results_dir> [--no-plots]

Primary comparison subject: hardened_enforced.
"""
import json
import os
import sys
import csv

PRIMARY = "hardened_enforced"
RUNTIME_ORDER = ["hardened_enforced", "stock", "gvisor", "docker"]
RUNTIME_LABEL = {
    "stock": "stock runc (ctr)",
    "hardened_enforced": "hardened enforced (bundle)",
    "gvisor": "gVisor (docker+runsc)",
    "docker": "Docker default",
}
LAUNCHER = {
    "stock": "containerd/ctr",
    "hardened_enforced": "runc bundle",
    "gvisor": "docker",
    "docker": "docker",
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
        if x >= 1000:
            return f"{x:,.0f}"
        return f"{x:.2f}"
    return str(x)


def rel_vs_primary(primary_val, val, direction):
    if primary_val is None or val is None or primary_val == 0:
        return "—"
    if direction == "low":
        return f"{(val / primary_val - 1) * 100:+.1f}%"
    return f"{(val / primary_val) * 100:.0f}% of enforced"


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
        if PRIMARY not in present:
            errors.append(f"{fname}: primary runtime '{PRIMARY}' absent")
    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: report.py <results_dir> [--no-plots]", file=sys.stderr)
        sys.exit(1)
    d = sys.argv[1]
    do_plots = "--no-plots" not in sys.argv[2:]
    md = []
    csv_rows = []

    validation_errors = validate_metrics(d)
    if validation_errors:
        md.append("## Validation warnings\n")
        for e in validation_errors:
            md.append(f"- {e}")
        md.append("")

    md.append("# Benchmark Report\n")
    md.append(f"Source: `{d}`\n")
    md.append(f"Primary subject: **{RUNTIME_LABEL[PRIMARY]}**\n")

    meta = os.path.join(d, "host-metadata.txt")
    if os.path.exists(meta):
        md.append("## Test Environment\n\n```\n" + open(meta).read().strip() + "\n```\n")

    md.append("## Performance Metrics\n")
    md.append(
        "Medians over repeated samples. "
        "'vs enforced' expresses baseline deviation from the primary subject "
        "(positive latency = slower than enforced; throughput shown as % of enforced).\n"
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
        primary_stats = res.get(PRIMARY, {})
        primary_median = primary_stats.get("median") if isinstance(primary_stats, dict) else None

        md.append(f"\n### {title} ({unit})\n")
        md.append("| Runtime | Launcher | median | p95 | stddev | vs enforced |")
        md.append("|---|---|---|---|---|---|")
        for r in runtimes:
            st = res.get(r, {})
            if not isinstance(st, dict):
                continue
            median = st.get("median")
            p95 = st.get("p95")
            sd = st.get("stddev")
            rel = "—" if r == PRIMARY else rel_vs_primary(primary_median, median, direction)
            md.append(
                f"| {RUNTIME_LABEL.get(r, r)} | {LAUNCHER.get(r, 'n/a')} | "
                f"{fmt(median)} | {fmt(p95)} | {fmt(sd)} | {rel} |"
            )
            csv_rows.append([title, unit, r, LAUNCHER.get(r, ""), fmt(median), fmt(p95), fmt(sd)])
            if median is not None:
                plot_data.setdefault(title, {})[r] = median
            cs = cold.get(r)
            if isinstance(cs, dict):
                cold_data.setdefault(title, {})[r] = cs.get("first_rep_ms", cs.get("median"))
            elif cs is not None:
                cold_data.setdefault(title, {})[r] = cs
        md.append("")

    if cold_data:
        md.append("## Cold-Start Wall Time (first measured rep, ms)\n")
        md.append("| Workload | " + " | ".join(RUNTIME_LABEL[r] for r in RUNTIME_ORDER if any(r in v for v in cold_data.values())) + " |")
        md.append("|" + "---|" * (1 + len([r for r in RUNTIME_ORDER if any(r in v for v in cold_data.values())])) )
        for title, series in cold_data.items():
            row = [title]
            for r in RUNTIME_ORDER:
                if r in series:
                    row.append(fmt(series[r]))
            if len(row) > 1:
                md.append("| " + " | ".join(row) + " |")
        md.append("")

    # Enforcement summaries committed with profiles (optional)
    prof_root = os.path.join(os.path.dirname(os.path.dirname(d)), "profiles")
    enf_items = []
    for wl in ("sysbench-cpu", "sysbench-mem", "network-iperf", "redis-app"):
        p = os.path.join(prof_root, f"enforcement-{wl}.json")
        if os.path.exists(p):
            try:
                enf_items.append(json.load(open(p)))
            except Exception:
                pass
    if enf_items:
        md.append("## Profile Enforcement Overhead (preparation phase)\n")
        md.append("| Workload | raw median (ms) | enforced median (ms) | overhead % |")
        md.append("|---|---|---|---|")
        for item in enf_items:
            raw = item.get("results", {}).get("raw", {}).get("median")
            enf = item.get("results", {}).get("enforced", {}).get("median")
            oh = item.get("enforcement_overhead_pct_median")
            md.append(f"| {item.get('workload')} | {fmt(raw)} | {fmt(enf)} | {fmt(oh)} |")
        md.append("")

    csv_path = os.path.join(d, "report.csv")
    with open(csv_path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["metric", "unit", "runtime", "launcher", "median", "p95", "stddev"])
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
                "hardened_enforced": "#2a9d8f",
                "stock": "#457b9d",
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
                fig, ax = plt.subplots(figsize=(8, 4.5))
                ax.bar(labels, vals, color=bar_colors)
                ax.set_title(title)
                ax.set_ylabel(title)
                plt.xticks(rotation=15, ha="right")
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
