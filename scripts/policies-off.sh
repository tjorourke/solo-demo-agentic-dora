#!/usr/bin/env bash
# Remove all the AuthorizationPolicies the demo applies — the bare-K8s
# pre-enforcement state. Solo is still installed (Istio Ambient mesh +
# agentgateway + kagent + agentregistry); only the runtime-defence
# policies get stripped.
#
# Old name was solo-off.sh; renamed because Solo isn't being turned off,
# the AuthorizationPolicies are. (The mesh is still there. SPIFFE
# identities are still issued. mTLS still STRICT. What changes is
# whether ztunnel enforces the deny rules.)
#
# Used by:
#   - reset-demo.sh (sets up the "before policies" state)
#   - operators reverting after a policies-on.sh
#
# Topology-aware: dispatches deletes to whichever cluster(s) actually host
# each namespace. Works in single or multi mode (auto-detected via
# scripts/lib/topology.sh). Override with MODE=single|multi.
#
# Run ./scripts/policies-on.sh to put Solo's protection back.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/topology.sh"
trap on_error ERR

log_step "Solo OFF — removing every protection layer (mode=$MODE)"

log "1/2 — removing Istio AuthorizationPolicies"
for ns in "$NS_BANK_MCP" "$NS_BANK_AGENTS" "$NS_BANK_VENDORS" external-attacker; do
  for cluster in $(clusters_for_ns "$ns"); do
    ctx="$(cluster_context "$cluster")"
    log "    $cluster:$ns"
    kubectl --context="$ctx" -n "$ns" delete authorizationpolicy --all \
      --ignore-not-found 2>&1 | sed 's/^/      /' || true
  done
done

log "2/2 — removing agentgateway tool-allowlist policies on the platform namespace"
for cluster in $(clusters_for_ns "$NS_PLATFORM"); do
  ctx="$(cluster_context "$cluster")"
  # Only the bank cluster has the AgentgatewayPolicy CRDs registered + the
  # routes they target. Skip clusters where the CRD isn't installed.
  if ! kubectl --context="$ctx" get crd agentgatewaypolicies.agentgateway.dev >/dev/null 2>&1; then
    continue
  fi
  log "    $cluster:$NS_PLATFORM"
  kubectl --context="$ctx" -n "$NS_PLATFORM" delete agentgatewaypolicy \
    account-mcp-allowlist transaction-mcp-allowlist ticket-mcp-allowlist \
    --ignore-not-found 2>&1 | sed 's/^/      /' || true
done

log "refreshing port-forwards"
OPEN_BROWSER=0 "$SCRIPT_DIR/port-forward.sh" 2>&1 | tail -1 | sed 's/^/    /' || true

echo ""
log_warn "TrustUsBank is now UNPROTECTED — bare K8s, no AuthZ."
log "Any compromised pod can reach any service, including external-attacker."
log "Restore protection with: ./scripts/policies-on.sh"
