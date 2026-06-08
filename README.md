# Container Runtime Performance & Security Evaluation

Reproducible benchmark + security-confinement harness for comparing **stock `runc`**, **hardened [`dpttk/runc`](https://github.com/dpttk/runc)** (raw and enforced with generated profiles), **gVisor (`runsc`)**, and **Docker** on a dedicated Linux host.

This repository supports the performance and security chapters of the bachelor thesis on automatic seccomp, AppArmor, and capability profile generation inside the OCI runtime. It answers two research questions: *what is the trade-off between a hardened traditional runtime, default `runc`, and sandboxed alternatives such as gVisor?* and *how much does automatically generated, workload-specific enforcement reduce the post-compromise attack surface, and at what runtime cost?*

The harness measures two axes:

- **(A) Performance** — startup/teardown latency, density, CPU, memory, disk I/O, network, and syscall-heavy application workloads, with statistical rigor (warmup + repeated samples; median / p95 / p99 / stddev).
- **(B) Security** — attack-surface metrics (capabilities, seccomp mode, AppArmor), a post-RCE confinement matrix, generated-profile cost, and functional-preservation checks.

One command runs everything and produces CSV + Markdown + plots:

```bash
sudo ./scripts/run-all.sh           # full campaign → results/campaign-<ts>/report.md
sudo ./scripts/run-all.sh --quick   # fast smoke run
```

Related artefacts:

| Repository | Role |
|------------|------|
| [`dpttk/runc`](https://github.com/dpttk/runc) | Hardened runtime fork with `--security-scan` and enforcement mode |
| [`runc-hardened-test`](https://github.com/dpttk/runc-hardened-test) | Security lab for generating and validating profiles (baseline vs hardened) |
| **this repository** | Performance measurement infrastructure |

## Compared configurations

The harness addresses every runtime through a stable **alias** (`scripts/lib/common.sh` runtime abstraction). The launch backend differs per runtime, which is deliberate and documented:

| Alias | Launcher | Binary | Posture |
|-------|----------|--------|---------|
| **stock** | `ctr` + `io.containerd.runc.v2` (`--runc-binary`) | upstream `opencontainers/runc` | containerd default spec (14 caps, no seccomp) |
| **hardened** | `ctr` + `io.containerd.runc.v2` (`--runc-binary`) | `dpttk/runc` | raw binary, containerd default spec |
| **hardened_enforced** | `runc-hardened run --bundle` | `dpttk/runc` | generated seccomp + AppArmor + 0 caps |
| **gVisor** | `docker run --runtime=runsc` | Google gVisor | user-space kernel sandbox |
| **docker** | `docker run` (default) | Docker's `runc` | Docker default seccomp + AppArmor + 14 caps |
| **kata** | (deferred) | — | needs `/dev/kvm`; off on this host |

> **Why gVisor runs through Docker:** containerd 2.2.x and the `runsc` v1 shim hang on this host (the shim stalls before the container init runs), while gVisor works perfectly via Docker. gVisor is therefore launched with `docker run --runtime=runsc`. This is methodologically clean — gVisor is compared against the `docker` default-`runc` runtime (same Docker launcher) to isolate the **pure sandbox cost**, while `stock` vs `hardened` isolates the **runc binary cost** on the containerd-native path. See `runtime_backend()` in `scripts/lib/common.sh`.

The hardened runtime's contribution shows in two layers, reported separately so the thesis claim is precise (profile generation is cheap at scan time; steady-state enforcement cost is what operators pay at runtime):

1. **Runtime binary path** — same containerd stack, different OCI binary (`stock` vs `hardened`).
2. **Enforcement mode** — workload-specific seccomp/AppArmor/capability profiles applied to an OCI bundle (`hardened_enforced`), generated automatically by `--security-scan`.

## Metrics

**Performance** (`scripts/lib/bench.sh`, orchestrated by `benchmark-perf.sh`; all reported as median/p95/p99/stddev over `REPS` samples after `WARMUP` discarded):

| Family | Measurement |
|--------|-------------|
| Startup latency | ms to run+exit a `busybox /bin/true` container |
| Density | wall time + memory delta to start N parallel containers (5/10/25/50/75) |
| CPU | sysbench CPU events/s |
| Memory | sysbench memory MiB/s |
| Disk I/O | `dd conv=fsync` write + cached read (MB/s) inside the container FS |
| Network | iperf3 loopback receiver throughput (Gbit/s) |
| Application | redis-benchmark SET/GET (syscall-heavy, server+client loopback) |

**Security** (`scripts/security/`):

| Family | Measurement | Script |
|--------|-------------|--------|
| Profile generation | one-time `--security-scan` cost + generated profile summary | `generate-profile.sh` |
| Enforcement overhead | raw vs enforced bundle latency + functional-preservation | `enforcement-bench.sh` |
| Attack surface | effective in-container caps / seccomp / AppArmor per runtime | `surface-metrics.sh` |
| Post-RCE confinement | ALLOWED/blocked matrix for a battery of attacker actions | `attack-matrix.sh` |

Results land in `results/<timestamp>/` (or `results/campaign-<ts>/` for `run-all.sh`) as one JSON file per metric, plus `host-metadata.txt`, `report.md`, `report.csv`, and `plots/`.

## Host requirements

Use a **dedicated VM** so numbers are not polluted by desktop workloads.

Recommended:

- Ubuntu 24.04 LTS (22.04 also works)
- 4 vCPU, 8 GiB RAM minimum
- cgroup v2 enabled
- root/sudo access
- outbound network (image pulls, Go/gVisor downloads)

Not required on the benchmark host:

- AppArmor scan tooling (that lives in `runc-hardened-test`)
- Kubernetes

## Quick start

```bash
git clone <this-repo-url> performance-evaluation
cd performance-evaluation

cp config.env.example config.env   # optional: adjust paths and iteration counts
sudo ./scripts/setup.sh            # installs runc/gVisor/Docker/bench+scan toolchain
sudo ./scripts/verify.sh           # checks every runtime + tool
sudo ./scripts/run-all.sh          # full performance + security campaign
```

Inspect output:

```bash
ls -la results/campaign-*/
cat results/campaign-*/report.md          # thesis-ready tables
column -s, -t results/campaign-*/report.csv | less
xdg-open results/campaign-*/plots/         # bar charts
```

Run individual suites instead of the whole campaign:

```bash
sudo ./scripts/benchmark-perf.sh                      # all performance metrics
sudo ./scripts/benchmark-perf.sh latency app          # selected metrics only
sudo ./scripts/security/generate-profile.sh syscalls docker.io/library/busybox:latest
sudo ./scripts/security/enforcement-bench.sh syscalls
sudo ./scripts/security/surface-metrics.sh
sudo ./scripts/security/attack-matrix.sh
sudo ./scripts/report.sh results/<dir>                # (re)aggregate any results dir
```

## Full workflow

### 1. Install and configure the host

```bash
sudo ./scripts/setup.sh
```

`setup.sh` performs, in order:

1. Installs build tools, containerd, sysbench, Python
2. Installs Go (if missing)
3. Builds stock and hardened `runc` binaries
4. Installs gVisor `runsc` **and** the `containerd-shim-runsc-v1` shim
5. Ensures containerd is running with a default config
6. Installs **Docker Engine** and registers `runsc` + `runc-hardened` as Docker runtimes (`install-docker.sh`)
7. Installs **benchmark tooling** — fio, iperf3, redis-tools, sysstat, matplotlib (`install-bench-tools.sh`)
8. Installs the **`--security-scan` toolchain** — bpftool, capable-bpfcc, AppArmor utils, bpffs (`install-scan-toolchain.sh`)
9. Builds and installs **`oci-seccomp-bpf-hook`** for seccomp profile generation (`install-seccomp-hook.sh`)
10. Pulls benchmark images into containerd and Docker
11. Attempts to build [Touchstone](https://github.com/lnsp/touchstone) (optional)

> All installer scripts run apt non-interactively (`DEBIAN_FRONTEND=noninteractive`). If `oci-seccomp-bpf-hook` cannot be built, scans still produce capability + AppArmor profiles; only seccomp generation is disabled.

Skip Touchstone when you already know the legacy tool will not compile on your host:

```bash
sudo ./scripts/setup.sh --skip-touchstone
```

### 2. Optional — measure enforcement-mode overhead

If the thesis should report hardened runtime cost **with generated profiles**, first produce profiles in the security lab:

```bash
# on the security-lab host
cd runc-hardened-test
sudo ./scripts/setup.sh
sudo ./scripts/scan.sh
sudo ./scripts/apply.sh
```

Copy the bundle to the benchmark host and register it:

```bash
sudo ./scripts/prepare-hardened-bundle.sh /path/to/runc-hardened-test/oci-bundle
echo 'HARDENED_BUNDLE_DIR=/path/to/performance-evaluation/bundles/hardened-workload' >> config.env
```

The fallback benchmark then adds `metrics.startup_ms_avg.hardened_bundle_enforcement` to the summary JSON.

### 3. Run benchmarks

Automatic mode (Touchstone when available, otherwise fallback):

```bash
sudo ./scripts/benchmark.sh
```

Explicit modes:

```bash
sudo ./scripts/benchmark.sh --fallback-only
sudo ./scripts/benchmark.sh --touchstone-only
sudo ./scripts/benchmark-touchstone.sh suites/performance.yaml
```

### 4. Collect evidence for the thesis

Archive per run:

- `results/*/summary.json` or Touchstone JSON/HTML
- `results/*/host-metadata.txt`
- `config.env` used on that host
- versions of `runc-stock`, `runc-hardened`, and `runsc`

Suggested table columns for the thesis:

| Runtime | Startup avg (ms) | Scale-50 (ms) | sysbench CPU (events/s) | sysbench mem (MiB/s) |
|---------|------------------|---------------|-------------------------|----------------------|

## Repository layout

```
performance-evaluation/
├── README.md
├── config.env.example          # tunables (paths, iteration counts, images)
├── config/
│   └── containerd-runtimes.toml.fragment
├── patches/
│   └── touchstone-go.mod       # modernized module file for legacy Touchstone
├── suites/                     # Touchstone suite definitions
├── bundles/hardened-workload/  # optional scanned OCI bundle target
├── results/                    # benchmark output (gitignored except .gitkeep)
└── scripts/
    ├── run-all.sh              # one-command full campaign (perf + security + report)
    ├── setup.sh                # one-shot host preparation
    ├── verify.sh               # prerequisite + per-runtime smoke check
    ├── build-runtimes.sh
    ├── install-{go,containerd,gvisor,touchstone}.sh
    ├── install-docker.sh       # Docker Engine + runsc/hardened runtimes
    ├── install-bench-tools.sh  # fio, iperf3, redis-tools, matplotlib
    ├── install-scan-toolchain.sh   # bpftool, capable-bpfcc, AppArmor, bpffs
    ├── install-seccomp-hook.sh # builds oci-seccomp-bpf-hook
    ├── pull-images.sh          # pulls into containerd + Docker
    ├── prepare-hardened-bundle.sh
    ├── benchmark-perf.sh       # performance suite orchestrator
    ├── report.sh / report.py   # aggregate JSON → CSV + Markdown + plots
    ├── benchmark.sh            # legacy entry point (Touchstone/fallback)
    ├── benchmark-fallback.sh   # legacy portable benchmarks
    ├── benchmark-touchstone.sh # legacy CRI benchmark matrix (optional)
    ├── lib/
    │   ├── common.sh           # runtime abstraction (run_ephemeral/capture/detached)
    │   ├── bench.sh            # performance metric modules
    │   ├── stats.sh            # median/p95/p99/stddev helpers
    │   └── measurement.sh      # CPU governor pinning, host metadata capture
    └── security/
        ├── generate-profile.sh # --security-scan → raw + enforced bundles
        ├── enforcement-bench.sh # raw vs enforced overhead + functional check
        ├── surface-metrics.sh  # effective caps/seccomp/AppArmor per runtime
        └── attack-matrix.sh    # post-RCE confinement battery
```

## Security evaluation

The security suite turns the manual confinement comparison into a scriptable matrix.

1. **Generate a profile** from a workload's benign behaviour:
   ```bash
   sudo ./scripts/security/generate-profile.sh syscalls docker.io/library/busybox:latest
   ```
   This exports a rootfs, runs the workload under `runc-hardened --security-scan` (recording syscalls via `oci-seccomp-bpf-hook`, capabilities via `capable-bpfcc`, and AppArmor via audit), and writes two runnable bundles sharing one rootfs: `bundles/scanned/syscalls/{raw,enforced}`. It records the one-time scan cost and a `profile-summary.json`.

2. **Enforcement overhead** — `enforcement-bench.sh` runs the raw and enforced bundles, verifies they produce identical output (functional preservation), and reports the steady-state overhead percentage. The overhead is only marked valid when the enforced workload does the same work.

3. **Attack surface** — `surface-metrics.sh` launches each runtime and reads the effective posture from `/proc/self/status` (capability popcount, seccomp filter mode, NoNewPrivs, AppArmor). `hardened_enforced` is read statically from its config.

4. **Post-RCE confinement** — `attack-matrix.sh` runs a battery of attacker actions (mount, sethostname, chroot, mknod, raw socket, set time, load module, setuid, userns, ptrace, …) inside each runtime and records ALLOWED vs blocked. `hardened_enforced` runs the battery under the benign-generated profile, demonstrating that a profile learned from normal behaviour blocks post-compromise abuse.

## Touchstone vs fallback

**Touchstone** is the CRI benchmark suite from Linsmaier (TUM, 2019), referenced in the thesis literature review. It compares containerd/CRI-O with `runc` and `runsc` through a formal benchmark matrix and HTML report.

Caveats:

- Last upstream update: 2019 (Kubernetes 1.14 era)
- This repo ships a modernized `go.mod`, but source imports may still fail to build
- Treat Touchstone as **best-effort**; cite it as methodology even if you report fallback numbers

**Fallback benchmarks** (`benchmark-fallback.sh`) are the supported path. They use `ctr` against the same three containerd handlers and emit a single `summary.json` that is easy to paste into thesis tables.

If both succeed, prefer Touchstone for CRI lifecycle numbers and fallback for the hardened-bundle enforcement measurement.

## Configuration reference

Copy `config.env.example` to `config.env`. Important variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `RUNC_STOCK_BIN` | `/usr/local/sbin/runc-stock` | upstream runc install path |
| `RUNC_HARDENED_BIN` | `/usr/local/sbin/runc-hardened` | hardened fork install path |
| `HARDENED_RUNC_SRC` | _(clone)_ | local path to fork source tree |
| `GVISOR_RELEASE` | `latest` | gVisor release tag (`latest` resolves the newest) |
| `RUNTIMES` | `stock hardened gvisor docker` | runtimes exercised by the suites |
| `REPS` / `WARMUP` | `30` / `5` | measured samples / discarded warmup samples |
| `DENSITY_SIZES` | `5 10 25 50 75` | parallel container counts for density |
| `FIO_*` / `IPERF_*` / `WRK_*` / `REDIS_BENCH_*` | see `config.env.example` | per-workload tunables |
| `SCAN_BUNDLES_DIR` | `./bundles/scanned` | generated profile bundles |
| `SCAN_UID` / `SCAN_GID` | `65532` | non-root uid/gid used during scans |
| `PROBE_IMAGE` | `busybox` | image for the post-RCE probe battery |
| `GENERATE_PLOTS` | `1` | emit matplotlib plots in the report |
| `PIN_CPU_GOVERNOR` | `1` | pin CPU governor to `performance` when writable |
| `RESULTS_DIR` | `./results` | output directory |

Legacy variables (`STARTUP_ITERATIONS`, `SCALABILITY_SIZES`, `HARDENED_BUNDLE_DIR`) still drive the older `benchmark-fallback.sh` path.

## Troubleshooting

**containerd crash loop / socket missing**

Fallback benchmarks only need a running containerd with its **default** config. Reset it:

```bash
sudo ./scripts/restore-containerd.sh
sudo ./scripts/install-containerd.sh
sudo ./scripts/verify.sh
```

Or manually:

```bash
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd
```

Do **not** run `configure-containerd.sh` unless you specifically need Touchstone/CRI handlers.

**`ctr: invalid runtime name runc` on containerd 2.x**

- containerd 2.x `ctr` expects `--runtime io.containerd.runc.v2`, a full binary path, or `io.containerd.runsc.v1` — not CRI handler names like `runc`.
- Ensure `config.env` defines:
  ```env
  CTR_RUNTIME_STOCK=/usr/local/sbin/runc-stock
  CTR_RUNTIME_HARDENED=/usr/local/sbin/runc-hardened
  CTR_RUNTIME_GVISOR=/usr/local/bin/runsc
  ```
- Re-copy updated scripts from the repo, then run:
  ```bash
  sudo ./scripts/verify.sh
  sudo ./scripts/benchmark.sh --fallback-only
  ```

**containerd fails to start / `toml: table runc already exists`**

- Caused by `configure-containerd.sh` (optional script — not needed for fallback benchmarks).
- Reset with `sudo ./scripts/restore-containerd.sh` and skip `configure-containerd.sh`.

**containerd fails to restart after configure**

- Inspect `config/containerd.config.toml.bak` (created on first configure run)
- Validate syntax: `containerd config dump`
- Restore backup: `sudo cp config/containerd.config.toml.bak /etc/containerd/config.toml`

**gVisor containers hang under `ctr` (containerd 2.2.x)**

- Known incompatibility on this host: the `io.containerd.runsc.v1` shim stalls before the container init runs. `runsc` itself works (`runsc --platform=systrap do echo hi` succeeds in <1 s).
- The harness therefore launches gVisor via **Docker** (`docker run --runtime=runsc`), which works reliably. No action needed — `runtime_backend gvisor` returns `docker`.
- gVisor uses the `systrap` platform automatically on VMs without `/dev/kvm`.

**gVisor containers fail to start under Docker**

- Confirm `runsc` is registered: `docker info | grep -i runtimes` should list `runsc`.
- Re-run `sudo ./scripts/install-docker.sh` to rewrite `/etc/docker/daemon.json`.
- Check `dmesg` and `/var/log/syslog` for `runsc` errors.

**Touchstone build fails**

- Run `sudo ./scripts/setup.sh --skip-touchstone`
- Use `sudo ./scripts/benchmark.sh --fallback-only`

**Hardened vs stock numbers are identical**

- Expected for CRI-path tests when profiles are not injected into containerd-created specs
- Use `prepare-hardened-bundle.sh` to measure enforcement-mode overhead separately

**Results vary between runs**

- Stop unrelated services on the benchmark VM
- Run multiple iterations and report median / p95
- Pin CPU frequency or document turbo behaviour in the thesis methodology section

## Methodology notes for thesis text

When writing up results, state explicitly:

1. **Fixed host** — same kernel, CPU count, and containerd version for all runtimes
2. **Same images** — identical container images per workload (`busybox`, `nginx`, `redis`)
3. **Two hardened measurements** — binary swap via containerd handler vs enforcement bundle with generated profiles
4. **gVisor baseline** — represents sandbox isolation overhead, not profile-based hardening
5. **Security lab separation** — profile generation runs in `runc-hardened-test`; performance runs in this repo

Expected qualitative outcome (consistent with Wang et al. 2022 and related work cited in the thesis):

- gVisor slowest on startup and syscall-heavy workloads
- stock `runc` fastest on raw lifecycle and I/O
- hardened `runc` between stock and gVisor, with enforcement-mode cost depending on profile tightness

## Licence and citation

Benchmark scripts in this repository are part of the thesis artefact. When linking from the thesis PDF, point readers to this repository for reproduction steps.

Touchstone is MIT-licensed: [lnsp/touchstone](https://github.com/lnsp/touchstone).

## Related reading

- Linsmaier, TUM thesis / Touchstone tool — CRI runtime benchmarking methodology
- Wang & Johannesson (2022) — runc vs gVisor performance and isolation
- [`dpttk/runc`](https://github.com/dpttk/runc) — hardened runtime implementation
- [`runc-hardened-test`](https://github.com/dpttk/runc-hardened-test) — security profile generation lab
