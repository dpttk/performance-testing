# Objectives

## Purpose

Quantify the steady-state performance cost of enforced security profiles on the
**proposed OCI runtime** relative to the same runtime without profiles and to
reference sandbox deployments.

## Primary subject

`proposed` — proposed runtime (`dpttk/runc`) with pre-generated seccomp, AppArmor,
and capability profiles.

## Reference runtimes

| Alias | Role |
|-------|------|
| `stock` | Proposed runtime binary, **no profiles** (enforcement baseline) |
| `docker` | Industry-default Docker deployment (sandbox baseline) |
| `gvisor` | Userspace-kernel sandbox (compared against docker) |

## Research questions

1. What is the enforcement overhead of security profiles (proposed vs stock)?
2. What is the sandbox overhead of gVisor (gvisor vs docker)?
3. Are workloads functionally preserved after profile application?

## Success criteria

- `stock` and `proposed` share one OCI bundle launcher
- `gvisor` and `docker` share one Docker launcher
- Reports show per-workload enforcement overhead (proposed vs stock)
