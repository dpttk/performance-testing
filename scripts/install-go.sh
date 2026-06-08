#!/usr/bin/env bash
# Install or refresh the Go toolchain used to build runc and Touchstone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

if command -v go >/dev/null 2>&1; then
    info "Go already installed: $(go version)"
    exit 0
fi

info "Installing Go ${GO_VERSION}..."
GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"
wget -q "https://go.dev/dl/${GO_TAR}" -O "/tmp/${GO_TAR}"
rm -rf /usr/local/go
tar -C /usr/local -xzf "/tmp/${GO_TAR}"
cat >/etc/profile.d/go.sh <<'EOF'
export PATH=$PATH:/usr/local/go/bin
EOF
export PATH="$PATH:/usr/local/go/bin"
info "Go installed: $(go version)"
