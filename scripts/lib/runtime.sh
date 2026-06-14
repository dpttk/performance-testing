#!/usr/bin/env bash
# Runtime abstraction layer for benchmark scripts.
#
# This module intentionally reuses helpers from common.sh so existing scripts
# can source a single runtime-oriented entrypoint.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
