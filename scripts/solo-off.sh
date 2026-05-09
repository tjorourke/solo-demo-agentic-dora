#!/usr/bin/env bash
# Strip Solo's protection layers — the bare-K8s starting state.
# This is the world before Solo is deployed. The infrastructure (Istio
# Ambient mesh, agentregistry, agentgateway, the agents) is still
# running, but no AuthorizationPolicies are enforcing — every pod can
# talk to every pod.
#
# Used by:
#   - reset-demo.sh (sets up the "before Solo" state)
#   - operators reverting after a deploy-solo.sh
#
# Run ./scripts/deploy-solo.sh to put Solo's protection back.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

log_step "Solo OFF — removing every protection layer"

log "1/2 — removing Istio AuthorizationPolicies"
for ns in "$NS_BANK_MCP" "$NS_BANK_AGENTS" "$NS_BANK_VENDORS" external-attacker; do
  kubectl -n "$ns" delete authorizationpolicy --all --ignore-not-found 2>&1 | sed 's/^/    /' || true
done

log "2/2 — removing agentgateway tool-allowlist policies (if any)"
kubectl -n "$NS_PLATFORM" delete agentgatewaypolicy \
  account-mcp-allowlist transaction-mcp-allowlist ticket-mcp-allowlist \
  --ignore-not-found 2>&1 | sed 's/^/    /' || true

log "refreshing port-forwards"
"$SCRIPT_DIR/port-forward.sh" 2>&1 | tail -1 | sed 's/^/    /' || true

echo ""
log_warn "TrustUsBank is now UNPROTECTED — bare K8s, no AuthZ."
log "Any compromised pod can reach any service, including external-attacker."
log "Restore protection with: ./scripts/deploy-solo.sh"
