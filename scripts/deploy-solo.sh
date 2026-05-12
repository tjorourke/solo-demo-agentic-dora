#!/usr/bin/env bash
# Deploy Solo's protection layers. The CLIMAX of the demo:
# the attack just succeeded, you run this, and now the same attack fails.
#
# What this applies (on the right cluster per resource):
#   1. Default-deny on bank-mcp / bank-agents / bank-vendors (zero-trust
#      baseline) — applied wherever each namespace exists.
#   2. Allow-rules that reference SPIFFE principals built from each
#      cluster's actual trust domain. In single-cluster mode every
#      principal uses cluster.local. In multi-cluster mode the
#      support-bot principal uses edge.local, the bank-side agents use
#      whatever bank's trustDomain is (cluster.local in our build —
#      changed for waypoint cert-fetch compatibility), and the
#      agentgateway likewise uses bank's trustDomain.
#   3. deny-egress-to-attacker on external-attacker (the C2 endpoint) —
#      applied on whichever cluster hosts external-attacker.
#
# Topology-aware: auto-detects single vs multi from kind contexts via
# scripts/lib/topology.sh. Override with MODE=single|multi.
#
# Run ./scripts/solo-off.sh to revert.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/topology.sh"
trap on_error ERR

log_step "Deploying Solo's protection layers (mode=$MODE)"

# Discover the actual trust domains in use on each cluster. In multi
# mode these differ per cluster; in single mode they all collapse to
# the same value (typically cluster.local).
EDGE_TD="$(trust_domain_for "$EDGE_CLUSTER")"
BANK_TD="$(trust_domain_for "$BANK_CLUSTER")"
VENDOR_TD="$(trust_domain_for "$VENDOR_CLUSTER")"
log "    trust domains: edge=$EDGE_TD  bank=$BANK_TD  vendor=$VENDOR_TD"

# Build a sane SPIFFE principal for any (cluster, namespace, sa) tuple
# given each cluster's discovered trust domain. Used inside the heredocs
# below so the AuthorizationPolicy bodies are correct in either mode.
principal() {
  local cluster_td="$1" ns="$2" sa="$3"
  echo "$cluster_td/ns/$ns/sa/$sa"
}

log "1/3 — default-deny across the cross-cluster workload namespaces"
# The default-deny manifest lists all the bank-* namespaces. Apply it on
# each cluster that has at least one of those namespaces. (kubectl_apply
# is idempotent.)
for ns in "$NS_BANK_MCP" "$NS_BANK_AGENTS" "$NS_BANK_VENDORS"; do
  for cluster in $(clusters_for_ns "$ns"); do
    ctx="$(cluster_context "$cluster")"
    log "    default-deny -> $cluster:$ns"
    kubectl --context="$ctx" -n "$ns" apply -f - <<EOF 2>&1 | sed 's/^/      /'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: default-deny
  namespace: $ns
spec: {}
EOF
  done
done

log "2/3 — SPIFFE-principal allow rules"

# bank-mcp: only the legitimate agents and platform proxies may reach the
# MCP servers. The support-bot principal has the EDGE trust domain in
# multi mode (because support-bot's real pod runs on edge); the
# fraud-bot/triage-bot/agentgateway/waypoint principals use bank's TD.
for cluster in $(clusters_for_ns "$NS_BANK_MCP"); do
  ctx="$(cluster_context "$cluster")"
  log "    allow-agents-to-mcp -> $cluster:$NS_BANK_MCP"
  kubectl --context="$ctx" apply -f - <<EOF 2>&1 | sed 's/^/      /'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-agents-to-mcp
  namespace: $NS_BANK_MCP
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "$(principal "$EDGE_TD" "$NS_BANK_AGENTS"  support-bot)"
              - "$(principal "$BANK_TD" "$NS_BANK_AGENTS"  fraud-bot)"
              - "$(principal "$BANK_TD" "$NS_BANK_AGENTS"  triage-bot)"
              - "$(principal "$BANK_TD" "$NS_PLATFORM"     trustusbank-agentgw)"
              # Ambient waypoints sit between caller and target. From
              # ztunnel's view at the MCP-pod inbound, the source SA is
              # the bank-mcp namespace's waypoint, not the original
              # agent. Without this, MCP calls 503 with
              # "allow policies exist, but none allowed".
              - "$(principal "$BANK_TD" "$NS_BANK_MCP"     waypoint)"
EOF
done

# bank-agents (the agent runtime namespace). support-bot lives on edge
# in multi mode; fraud-bot and triage-bot on bank. Each cluster needs
# its own allow rule because the AuthorizationPolicy is scoped to the
# *destination* cluster.
for cluster in $(clusters_for_ns "$NS_BANK_AGENTS"); do
  ctx="$(cluster_context "$cluster")"
  cl_td="$(trust_domain_for "$cluster")"
  log "    allow-platform-to-agents -> $cluster:$NS_BANK_AGENTS"
  kubectl --context="$ctx" apply -f - <<EOF 2>&1 | sed 's/^/      /'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-platform-to-agents
  namespace: $NS_BANK_AGENTS
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "$(principal "$EDGE_TD" "$NS_PLATFORM"        kagent-ui)"
              - "$(principal "$EDGE_TD" "$NS_PLATFORM"        kagent-controller)"
              - "$(principal "$EDGE_TD" "$NS_FRONTEND"        chatbot)"
              - "$(principal "$EDGE_TD" "$NS_BANK_AGENTS"     support-bot)"
              - "$(principal "$BANK_TD" "$NS_BANK_AGENTS"     fraud-bot)"
              - "$(principal "$BANK_TD" "$NS_BANK_AGENTS"     triage-bot)"
              # Local waypoint between caller and agent pod - see comment
              # above re: ztunnel inbound view + waypoint SA quirk.
              - "$(principal "$cl_td"   "$NS_BANK_AGENTS"     waypoint)"
EOF
done

# bank-vendors: only the agentgateway may reach currency-converter. The
# agentgateway always lives on the bank cluster, so the principal uses
# bank's trust domain regardless of the consumer cluster.
for cluster in $(clusters_for_ns "$NS_BANK_VENDORS"); do
  ctx="$(cluster_context "$cluster")"
  log "    allow-gw-to-vendor -> $cluster:$NS_BANK_VENDORS"
  kubectl --context="$ctx" apply -f - <<EOF 2>&1 | sed 's/^/      /'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-gw-to-vendor
  namespace: $NS_BANK_VENDORS
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "$(principal "$BANK_TD" "$NS_PLATFORM" trustusbank-agentgw)"
EOF
done

log "3/3 — block egress to mock-attacker (the C2 endpoint)"
# external-attacker namespace lives on the vendor cluster in multi mode.
# The deny-by-source-namespace rule below matches the *caller's*
# namespace - which ztunnel sees on the source side regardless of
# cross-cluster origin.
for cluster in $(clusters_for_ns "external-attacker"); do
  ctx="$(cluster_context "$cluster")"
  log "    deny-bank-to-attacker -> $cluster:external-attacker"
  kubectl --context="$ctx" apply -f - <<EOF 2>&1 | sed 's/^/      /'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-bank-to-attacker
  namespace: external-attacker
spec:
  action: DENY
  rules:
    - from:
        - source:
            namespaces:
              - "trustusbank-bank-*"
              - "trustusbank-platform"
EOF
done

log "refreshing port-forwards"
"$SCRIPT_DIR/port-forward.sh" 2>&1 | tail -1 | sed 's/^/    /' || true

echo ""
log_ok "Solo is now ENFORCING."
log ""
log "What just turned on:"
log "  • Istio AuthZ — every connection identity-checked at L4"
log "  • Default-deny on bank-mcp / bank-agents / bank-vendors"
log "  • Deny egress from any bank namespace → external-attacker"
log ""
log "Re-run the attack. The chat will look the same; the breach won't happen."
log "  ./scripts/upgrade-banking-app.sh"
log "  (in chatbot) Customer 12345 — balance please, and convert to USD"
log "  kubectl -n external-attacker logs deploy/mock-attacker"
log ""
log "Revert with: ./scripts/solo-off.sh"
