#!/usr/bin/env bash
# Remove kagent Enterprise AccessPolicy CRs from the bank cluster.
# Counterpart to scripts/policies-kagent-on.sh.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/topology.sh"
trap on_error ERR

CTX="$(cluster_context "$BANK_CLUSTER")"
NS="$NS_BANK_AGENTS"

log_step "kagent AccessPolicy: turning OFF (bank cluster, $NS)"

if ! kubectl --context="$CTX" get crd accesspolicies.policy.kagent-enterprise.solo.io >/dev/null 2>&1; then
  log_warn "AccessPolicy CRD not found — nothing to revert."
  exit 0
fi

log "deleting AccessPolicy CRs in $NS"
kubectl --context="$CTX" -n "$NS" delete accesspolicy --all --ignore-not-found 2>&1 | sed 's/^/    /'

# The kagent.solo.io/waypoint label is left in place — it's a property of
# the Agent itself, not the policy. Re-running policies-kagent-on.sh
# expects to find it.

log_ok "kagent AccessPolicy is now OFF."
log "  All callers can again invoke any Agent. Re-enable with:"
log "    scripts/policies-kagent-on.sh"
