#!/usr/bin/env bash
# Runtime abstraction layer for benchmark scripts.
#
# Re-exports common.sh (paths, RUNTIMES, ctr/docker helpers, smoke tests) so
# entrypoint scripts can source a single module instead of common.sh directly.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
