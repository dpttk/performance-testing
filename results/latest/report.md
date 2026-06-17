# Benchmark Report

Source: `./results/campaign-20260616-193735`

Primary subject: **Proposed runtime (enforced)**. Enforcement overhead: proposed vs stock (same binary, same OCI bundle launcher). Sandbox overhead: gVisor vs Docker default.

## Test Environment

```
host=perf-bench
date=2026-06-16T19:40:07+00:00
kernel=6.8.0-124-generic
arch=x86_64
cpu_model=AMD Ryzen 7 7700 8-Core Processor
cpu_count=4
virt=oracle
kvm_present=no
mem_total=8129808 kB
cgroup=cgroup2fs
cpu_governor=n/a
turbo_disabled=n/a
os=Ubuntu 24.04.4 LTS
containerd=containerd github.com/containerd/containerd/v2 2.2.1 
docker=Docker version 29.1.3, build 29.1.3-0ubuntu3~24.04.2
runc_stock=runc version 1.5.0-rc.1+dev
runc_proposed=runc version 1.4.0-rc.1+dev
runsc=runsc version release-20250319.0
kata=missing
runtimes_under_test=stock proposed gvisor docker
reps=50 warmup=10
profiles_dir=./profiles
launcher_stock=/usr/local/sbin/runc-hardened run --bundle
launcher_proposed=/usr/local/sbin/runc-hardened run --bundle
launcher_gvisor=docker(--runtime=runsc)
launcher_docker=docker(default)
```

## Performance Metrics

Medians over repeated samples. **Overhead** is positive when the runtime is worse than its baseline (lower throughput). stock and docker rows are baselines.


### CPU (sysbench) (events/s)

| Runtime | Launcher | median | p95 | stddev | overhead vs baseline |
|---|---|---|---|---|---|
| Proposed runtime (no profiles) | OCI bundle | 2,332 | 2,386 | 72.81 | baseline |
| Proposed runtime (enforced) | OCI bundle | 2,346 | 2,388 | 55.92 | -0.62% |
| Docker default | Docker | 2,342 | 2,383 | 59.17 | baseline |
| gVisor | Docker | 2,282 | 2,359 | 65.56 | +2.57% |


### Memory (sysbench) (MiB/s)

| Runtime | Launcher | median | p95 | stddev | overhead vs baseline |
|---|---|---|---|---|---|
| Proposed runtime (no profiles) | OCI bundle | 6,105,132 | 6,241,565 | 88,736 | baseline |
| Proposed runtime (enforced) | OCI bundle | 6,059,380 | 6,128,915 | 74,111 | +0.75% |
| Docker default | Docker | 6,360,881 | 6,473,053 | 116,844 | baseline |
| gVisor | Docker | 1,688,603 | 1,717,822 | 21,166 | +73.45% |


### Network (iperf3 loopback) (Gbit/s)

| Runtime | Launcher | median | p95 | stddev | overhead vs baseline |
|---|---|---|---|---|---|
| Proposed runtime (no profiles) | OCI bundle | 55.20 | 57.50 | 2.32 | baseline |
| Proposed runtime (enforced) | OCI bundle | 55.85 | 57.45 | 2.65 | -1.18% |
| Docker default | Docker | 55.65 | 57.45 | 2.29 | baseline |
| gVisor | Docker | 38.50 | 42.38 | 2.57 | +30.82% |


### Redis SET (req/s)

| Runtime | Launcher | median | p95 | stddev | overhead vs baseline |
|---|---|---|---|---|---|
| Proposed runtime (no profiles) | OCI bundle | 89,358 | 90,727 | 2,550 | baseline |
| Proposed runtime (enforced) | OCI bundle | 84,324 | 88,028 | 2,701 | +5.63% |
| Docker default | Docker | 87,100 | 88,139 | 2,728 | baseline |
| gVisor | Docker | 30,844 | 31,177 | 491.58 | +64.59% |


### Redis GET (req/s)

| Runtime | Launcher | median | p95 | stddev | overhead vs baseline |
|---|---|---|---|---|---|
| Proposed runtime (no profiles) | OCI bundle | 89,542 | 90,707 | 2,587 | baseline |
| Proposed runtime (enforced) | OCI bundle | 84,587 | 87,993 | 2,738 | +5.53% |
| Docker default | Docker | 87,176 | 88,464 | 2,668 | baseline |
| gVisor | Docker | 30,762 | 31,074 | 494.27 | +64.71% |

## Proposed Runtime Enforcement Overhead (proposed vs stock)

| Workload | stock median | proposed median | enforcement overhead |
|---|---|---|---|
| CPU (sysbench) | 2,332 | 2,346 | **-0.62%** |
| Memory (sysbench) | 6,105,132 | 6,059,380 | **+0.75%** |
| Network (iperf3 loopback) | 55.20 | 55.85 | **-1.18%** |
| Redis SET | 89,358 | 84,324 | **+5.63%** |
| Redis GET | 89,542 | 84,587 | **+5.53%** |

## Cold-Start Wall Time (first measured rep, ms)

| Workload | Proposed runtime (no profiles) | Proposed runtime (enforced) | Docker default | gVisor |
|---|---|---|---|---|
| CPU (sysbench) | 10069 | 10078 | 10230 | 10369 |
| Memory (sysbench) | 409 | 411 | 542 | 1639 |
| Network (iperf3 loopback) | 32074 | 32073 | 32247 | 32410 |
| Redis SET | 12208 | 13138 | 12710 | 34484 |
| Redis GET | 12208 | 13138 | 12710 | 34484 |


## Plots

![plots/CPU__sysbench_.png](plots/CPU__sysbench_.png)

![plots/Memory__sysbench_.png](plots/Memory__sysbench_.png)

![plots/Network__iperf3_loopback_.png](plots/Network__iperf3_loopback_.png)

![plots/Redis_SET.png](plots/Redis_SET.png)

![plots/Redis_GET.png](plots/Redis_GET.png)

