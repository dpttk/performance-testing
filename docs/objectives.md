# Objectives

## Purpose

Quantify the steady-state performance cost of enforced security profiles on a
hardened OCI runtime relative to common baseline deployments.

## Primary subject

`hardened_enforced` — `dpttk/runc` executing OCI bundles with pre-generated
seccomp, AppArmor, and capability profiles derived from each benchmark workload.

## Baselines

| Alias | Role |
|-------|------|
| `stock` | Upstream `runc` via containerd; native low-level reference |
| `gvisor` | Userspace-kernel sandbox via Docker |
| `docker` | Industry-default container deployment posture |

## Research questions

1. What is the enforcement overhead of hardened profiles per workload class?
2. How does `hardened_enforced` throughput compare to each baseline under identical workloads?
3. Are functional semantics preserved after profile application (raw output equals enforced output)?

## Success criteria

- All four runtimes complete every workload with identical commands.
- Pre-generated profiles are committed under `profiles/` and pass functional verification before measurement.
- Full campaigns use `REPS >= 50` and publish to `results/latest/`.
- Reports present `hardened_enforced` as the primary comparison subject.

## Non-goals

- Trivial startup probes (`/bin/true`) as benchmark workloads.
- Security scanning during the measurement phase.
- Cross-host absolute performance claims without environment metadata.
