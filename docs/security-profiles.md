# Security Profiles

## Overview

Security profiles are generated offline per workload before any performance
measurement. The measurement pipeline consumes prebuilt profiles only.

## Generation

```bash
sudo ./scripts/prepare-profiles.sh [workload-id ...]
```

Default targets: `sysbench-cpu`, `sysbench-mem`, `network-iperf`, `redis-app`.

### Procedure per workload

1. Export rootfs from the workload container image into `profiles/<workload>/rootfs/` (local cache, not committed).
2. Generate an OCI bundle specification with non-root UID/GID (`SCAN_UID`/`SCAN_GID`).
3. Execute `runc-hardened run --security-scan` against the workload command.
4. Split outputs into:
   - `raw/config.json` — pre-scan configuration
   - `enforced/config.json` — post-scan configuration with generated policies
   - `enforced/generated/` — seccomp JSON, AppArmor profile, capability logs
5. Write `manifest.yaml` with image digest, scan duration, and policy summary.
6. Run functional verification (enforced output fingerprint must equal raw).
7. Optionally measure enforcement overhead when `MEASURE_ENFORCEMENT_OVERHEAD=1`.

## Repository layout

```text
profiles/
  sysbench-cpu/
    manifest.yaml
    raw/config.json
    enforced/config.json
    enforced/generated/
  enforcement-sysbench-cpu.json   # optional overhead artifact
```

Committed paths: `manifest.yaml`, `raw/`, `enforced/` (excluding runtime rootfs).

## Policy contents

| Mechanism | Source |
|-----------|--------|
| Seccomp | `oci-seccomp-bpf-hook` + BPF syscall trace |
| AppArmor | File access trace during scan |
| Capabilities | `capable-bpfcc` effective capability log |

## Enforcement overhead

When enabled during preparation, the harness measures wall-clock time to execute
the full workload command on `raw` vs `enforced` bundles. Results are written to
`profiles/enforcement-<workload>.json` and referenced in the campaign report.

Overhead is reported only when functional verification passes.

## Measurement-phase constraints

`scripts/run.sh` validates that every committed profile exists and passes a
functional re-check. It does not invoke `--security-scan`.
