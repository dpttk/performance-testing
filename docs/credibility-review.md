# Credibility Review Checklist

Review this list after each methodology or tooling change and after each campaign.

## Runtime fairness

- [ ] `stock` and `proposed` use the **same binary** and **same OCI bundle launcher**
- [ ] Only difference between stock and proposed is raw vs enforced bundle config
- [ ] `gvisor` and `docker` use the **same Docker launcher**
- [ ] No upstream `runc-stock` in the benchmark comparison matrix

## Workload fairness

- [ ] All four runtimes execute identical workload commands per metric
- [ ] No trivial probes (`/bin/true`) in benchmark metrics
- [ ] Per-workload security profiles (not one shared busybox profile)

## Measurement integrity

- [ ] Profiles generated offline; no `--security-scan` during `run.sh`
- [ ] Functional check passes for every workload before measurement
- [ ] Full campaigns use `REPS >= 50`; quick runs excluded from `results/latest/`

## Overhead reporting

- [ ] Enforcement overhead = proposed vs stock per workload
- [ ] Sandbox overhead = gvisor vs docker per workload
- [ ] Baseline rows labelled explicitly in reports

## Environment

- [ ] `host-metadata.txt` records launcher mapping, binary versions, virt mode
- [ ] Dedicated benchmark VM preferred (KVM, cpufreq, minimal background load)
- [ ] Proposed binary rebuilt from pinned ref when comparing versions

## Open risks (current)

| Risk | Mitigation |
|------|------------|
| Two launcher families (bundle vs Docker) | Documented; unavoidable for OCI profile enforcement |
| Post-scan AppArmor patches | Required for shell/network/tmp; document in security-profiles.md |
| Docker baseline ≠ bare OCI | Expected; docker is the industry reference for gVisor |
| VM cpufreq unavailable | Use dedicated KVM guest; note in report metadata |

## Questions to ask before publishing results

1. Would stock→proposed delta change if both used Docker? (Yes — profiles need bundle path)
2. Is proposed faster than stock on any metric? (Investigate — should be ≤ stock throughput)
3. Are gVisor numbers stable across REPS? (High variance → extend campaign or fix pinning)
4. Do committed profiles match the workload image digests in manifests?
