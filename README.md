# OCI Runtime Performance Evaluation

This repository measures the performance impact of enforced security profiles on a
**proposed OCI runtime** (`dpttk/runc`) against reference deployments under identical
workloads.

## Runtime matrix

| Alias | Description | Launcher |
|-------|-------------|----------|
| `stock` | Proposed runtime binary, **no** security profiles (raw bundle) | OCI bundle |
| `proposed` | Proposed runtime binary, **with** enforced profiles | OCI bundle (same as stock) |
| `docker` | Docker Engine default posture (baseline for gVisor) | Docker |
| `gvisor` | gVisor userspace kernel | Docker |

**Overhead definitions**

- **Enforcement overhead** = `proposed` vs `stock` (isolates profile cost; same binary and launcher)
- **Sandbox overhead** = `gvisor` vs `docker` (isolates sandbox cost; same Docker launcher)

## Workflow

```bash
cp config.env.example config.env
sudo ./scripts/setup.sh
sudo ./scripts/prepare-profiles.sh
sudo ./scripts/run.sh
```

## Documentation

- [Objectives](docs/objectives.md)
- [Methodology](docs/methodology.md)
- [Credibility review](docs/credibility-review.md)
- [Test environment](docs/test-environment.md)
- [Workloads](docs/workloads.md)
- [Security profiles](docs/security-profiles.md)
- [Reporting](docs/reporting.md)
