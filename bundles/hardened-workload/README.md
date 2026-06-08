# Hardened OCI bundle (optional)

This directory is populated by `scripts/prepare-hardened-bundle.sh`.

Copy a scanned and applied OCI bundle from the [runtime security lab](https://github.com/dpttk/runc-hardened-test) to measure **enforcement-mode** startup overhead with generated seccomp, AppArmor, and capability profiles.

Without this bundle, containerd-based benchmarks still compare the three runtime binaries, but they do not include workload-specific profile enforcement cost.
