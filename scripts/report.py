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

RUNTIME_ORDER = ["stock", "hardened", "hardened_enforced", "gvisor", "docker", "kata"]
RUNTIME_LABEL = {
    "stock": "stock runc (ctr)",
    "hardened": "hardened raw (ctr)",
    "hardened_enforced": "hardened enforced",
    "gvisor": "gVisor",
    "docker": "Docker default",
    "kata": "Kata",
}

# metric file -> (title, unit, direction) ; direction: 'low' or 'high' better
SCALAR_METRICS = [
    ("latency.json", "Startup latency", "ms", "low"),
    ("sysbench-cpu.json", "CPU (sysbench)", "events/s", "high"),
    ("sysbench-mem.json", "Memory throughput (sysbench)", "MiB/s", "high"),
    ("disk-write.json", "Disk write (dd fsync)", "MB/s", "high"),
    ("disk-read.json", "Disk read (cached)", "MB/s", "high"),
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

    # ---- Density ----
    dens = load(d, "density.json")
    if dens and "results" in dens:
        md.append("\n### Container density (parallel start)\n")
        # collect sizes
        sizes = set()
        for r, v in dens["results"].items():
            if isinstance(v, dict):
                sizes.update(v.keys())
        sizes = sorted(sizes, key=lambda x: int(x))
        runtimes = order_runtimes(dens["results"].keys())
        md.append("| Runtime | " + " | ".join(f"{s} (ms / MiB-per-ctr)" for s in sizes) + " |")
        md.append("|---|" + "|".join(["---"] * len(sizes)) + "|")
        for r in runtimes:
            v = dens["results"].get(r, {})
            cells = []
            for s in sizes:
                e = v.get(s, {}) if isinstance(v, dict) else {}
                cells.append(f"{fmt(e.get('wall_ms'))} / {fmt(e.get('mem_per_container_mib'))}")
            md.append(f"| {RUNTIME_LABEL.get(r, r)} | " + " | ".join(cells) + " |")
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

    # ---- Attack surface ----
    surf = load(d, "surface.json")
    if surf and "results" in surf:
        md.append("\n## Attack surface (effective in-container posture)\n")
        md.append("| Runtime | capabilities | seccomp | NoNewPrivs | AppArmor | allowed syscalls |")
        md.append("|---|---|---|---|---|---|")
        for r in order_runtimes(surf["results"].keys()):
            v = surf["results"][r]
            md.append(f"| {RUNTIME_LABEL.get(r, r)} | {v.get('cap_count')} | "
                      f"{v.get('seccomp_mode')} | {v.get('no_new_privs')} | "
                      f"{v.get('apparmor_profile')} | {v.get('seccomp_allowed_syscalls', '—')} |")
            plot_data.setdefault("Capabilities (count)", {})[r] = v.get("cap_count")
        md.append("")

    # ---- Attack matrix ----
    atk = load(d, "attack-matrix.json")
    if atk and "matrix" in atk:
        md.append("\n## Post-RCE confinement matrix\n")
        md.append("ALLOWED = attacker action succeeded (worse); blocked = stopped by runtime/profile.\n")
        cols = order_runtimes(atk["matrix"].keys())
        md.append("| Probe | " + " | ".join(RUNTIME_LABEL.get(c, c) for c in cols) + " |")
        md.append("|---|" + "|".join(["---"] * len(cols)) + "|")
        for p in atk["probes"]:
            cells = [atk["matrix"][c].get(p, "?") for c in cols]
            cells = ["**ALLOWED**" if x == "ALLOWED" else ("blocked" if x == "BLOCKED" else x) for x in cells]
            md.append(f"| {p} | " + " | ".join(cells) + " |")
        md.append("| **ALLOWED total** | " +
                  " | ".join(str(atk.get("allowed_counts", {}).get(c, "?")) for c in cols) + " |")
        md.append("")
        plot_data["Post-RCE actions ALLOWED (lower=better)"] = atk.get("allowed_counts", {})

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
