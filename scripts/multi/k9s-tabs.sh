#!/usr/bin/env bash
# Open three macOS Terminal tabs, one per cluster, running k9s against
# that cluster's kubectl context. Run from the repo root.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT MODE=multi
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/topology.sh"

[[ "$(uname)" == "Darwin" ]] || { echo "macOS-only (Terminal.app via osascript)"; exit 1; }
command -v k9s >/dev/null || { echo "k9s not on PATH — brew install k9s"; exit 1; }

# Order: edge, bank, vendor — opened as new tabs in the frontmost Terminal window.
for cluster in "$EDGE_CLUSTER" "$BANK_CLUSTER" "$VENDOR_CLUSTER"; do
  ctx="kind-${cluster}"
  log "opening k9s tab for $cluster ($ctx)"
  osascript <<EOF
tell application "Terminal"
  activate
  tell application "System Events" to keystroke "t" using {command down}
  delay 0.4
  do script "k9s --context=$ctx" in front window
end tell
EOF
done

log_ok "k9s tabs opened. Use ⌘1/2/3 to switch."
echo "Or run manually:"
echo "  k9s --context=kind-$EDGE_CLUSTER"
echo "  k9s --context=kind-$BANK_CLUSTER"
echo "  k9s --context=kind-$VENDOR_CLUSTER"
