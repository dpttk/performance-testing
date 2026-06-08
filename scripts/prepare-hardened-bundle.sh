#!/usr/bin/env bash
# Link or copy a scanned OCI bundle from the runtime security lab.
#
# Usage:
#   sudo ./scripts/prepare-hardened-bundle.sh /path/to/runc-hardened-test/oci-bundle
#
# The bundle must contain generated seccomp/AppArmor/capability profiles already
# applied to config.json (run scan.sh + apply.sh in the security lab first).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

SRC="${1:-}"
[[ -n "$SRC" ]] || error "Usage: $0 /path/to/oci-bundle"

SRC="$(cd "$SRC" && pwd)"
[[ -f "$SRC/config.json" ]] || error "Missing config.json in $SRC"

DEST="$PERF_DIR/bundles/hardened-workload"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$SRC/." "$DEST/"

info "Prepared hardened bundle at $DEST"
info "Set HARDENED_BUNDLE_DIR=$DEST in config.env for bundle-based benchmarks."
