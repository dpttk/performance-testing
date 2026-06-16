# Test Environment

## Hardware requirements

- Linux host with cgroup v2
- Minimum 4 CPU cores and 8 GiB RAM recommended
- Root privileges for runtime installation and benchmark execution

## Software stack

Installed by `scripts/setup.sh`:

| Component | Purpose |
|-----------|---------|
| containerd 2.x | `stock` runtime launcher |
| Docker Engine | `gvisor` and `docker` runtime launcher |
| `runc-stock` | Upstream runc binary (pinned ref) |
| `runc-hardened` | Hardened fork binary |
| `runsc` | gVisor runtime |
| sysbench, iperf3, redis-benchmark | Workload tooling inside containers |
| bpftool, capable-bpfcc, apparmor_parser | Profile generation toolchain |
| oci-seccomp-bpf-hook | Seccomp BPF profile generation |

## Runtime binary alignment

Both `runc-stock` and `runc-hardened` are built via `scripts/build-runtimes.sh`:

- Stock: `opencontainers/runc` at `RUNC_STOCK_REF` (default `RUNC_BASE_REF`)
- Hardened: `dpttk/runc` at `HARDENED_RUNC_REF`

Set `FORCE_REBUILD_RUNTIMES=1` in `config.env` to rebuild aligned binaries.

## containerd configuration

- Socket: `/run/containerd/containerd.sock`
- Namespace: `performance-eval` (isolated from system workloads)
- Stock runtime selected via `ctr --runc-binary /usr/local/sbin/runc-stock`

## Docker configuration

`/etc/docker/daemon.json` registers additional runtimes when
`DOCKER_REGISTER_EXTRA_RUNTIMES=1`:

- `runsc` — gVisor
- `runc-hardened` — optional cross-check (not used in default benchmarks)

## Image management

Container images are pulled by `scripts/pull-images.sh`. Profile manifests record
the image digest at preparation time (`profiles/<workload>/manifest.yaml`).

## Host hygiene

| Control | Configuration |
|---------|---------------|
| CPU governor | `PIN_CPU_GOVERNOR=1` sets performance mode when cpufreq is writable |
| CPU affinity | Optional `PIN_CPU_CORES` via taskset |
| Metadata capture | `host-metadata.txt` per campaign |

## Verification

```bash
sudo ./scripts/verify.sh
```

Checks binaries, container engines, images, scan toolchain, and executes a minimal
`sysbench-cpu` workload smoke test on every runtime.
