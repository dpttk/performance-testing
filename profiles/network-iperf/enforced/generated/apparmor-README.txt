AppArmor (automatic with --security-scan)
========================================

During the scan run runc writes generated/apparmor.profile (a stub in
complain mode with abstractions/base, nameservice, ssl_certs included),
loads it via apparmor_parser -r, sets process.apparmorProfile, and
records AppArmor policy audit events for the profile in the kernel
ring. In complain mode these are usually apparmor=ALLOWED records for
accesses that would have been denied in enforce mode. On poststop the
runtime pulls those events out of journalctl (or dmesg as a fallback),
turns them into file and capability rules, and appends them between
sentinel markers inside the profile body.

After the container exits, finalizeSecurityScan:
  * writes the profile name into process.apparmorProfile in config.json,
  * flips the on-disk profile out of complain mode into enforce when
    audit-collected rules are present (otherwise complain stays).

Subsequent non-scan runc invocations on the same bundle pick the
profile up automatically: ensureGeneratedProfiles loads it via
apparmor_parser -r before starting the container.

If AppArmor is disabled on the host the profile file is still written
for reference; load/unload and audit collection are skipped. See
generated/apparmor-load.log after each run for diagnostics.
