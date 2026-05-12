#!/usr/bin/env bash
# Apply Solo's runtime-defence AuthorizationPolicies. Solo is already
# installed at this point (Istio Ambient mesh + agentgateway + kagent +
# agentregistry); this is the toggle that turns enforcement on. After
# the attack succeeded, you run this, and now the same attack fails.
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
# Run ./scripts/policies-off.sh to revert.
# (Old name was deploy-solo.sh; renamed because Solo is already
# deployed when you run this - what you're toggling is the policies.)

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

# In multi-cluster mode, cross-cluster traffic arrives via the lateral
# hack (NodePort + manual EndpointSlice in manifests/multi/lateral-hack.
# yaml). That path SNATs the source IP through kube-proxy on the
# destination node, which strips the SPIFFE identity before ztunnel sees
# the packet. ANY default-deny on the SNAT'd destination namespace
# (bank-mcp, bank-agents, OR bank-vendors) will therefore reject the
# lateral-hack inbound and break the demo's first hop with 503.
#
# In single-cluster mode there's no SNAT in the path, SPIFFE identities
# are intact end-to-end, and the full deny+allow ruleset is appropriate.
#
# The demo's load-bearing claim — currency-converter cannot exfiltrate
# to mock-attacker — depends ONLY on the deny-bank-to-attacker policy on
# external-attacker. That source side is intra-vendor (currency-converter
# is on vendor, mock-attacker is on vendor) so SPIFFE is intact and the
# source.namespaces match works. So in multi mode we apply ONLY that
# one policy. Defence-in-depth ruleset is single-cluster only.
APPLY_DEFENCE_IN_DEPTH=1
if [[ "$MODE" == "multi" ]]; then
  APPLY_DEFENCE_IN_DEPTH=0
  log "[multi mode] applying ONLY the deny-bank-to-attacker policy."
  log "  The bank-mcp / bank-agents / bank-vendors policies are skipped"
  log "  because the lateral hack SNATs cross-cluster traffic, losing SPIFFE"
  log "  identity, and a default-deny on those namespaces would 503 the demo's"
  log "  forward flow. The egress block from currency-converter to mock-attacker"
  log "  is intra-vendor so SPIFFE is preserved and source.namespaces matches."
fi

log "1/3 — default-deny on cross-cluster workload namespaces"
# Note: macOS bash 3.2 errors on empty-array expansion under set -u, so use
# the ${VAR[@]+"${VAR[@]}"} guard (expands to nothing if the array is unset
# or empty, prevents the unbound-variable trap).
DENY_NAMESPACES=()
[[ "$APPLY_DEFENCE_IN_DEPTH" == "1" ]] && DENY_NAMESPACES=("$NS_BANK_MCP" "$NS_BANK_AGENTS" "$NS_BANK_VENDORS")
for ns in "${DENY_NAMESPACES[@]+"${DENY_NAMESPACES[@]}"}"; do
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

# bank-mcp + bank-agents allow rules: only meaningful when default-deny
# is in place on those namespaces. Skipped in multi mode (see above).
if [[ "$APPLY_DEFENCE_IN_DEPTH" == "1" ]]; then
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
fi  # end APPLY_DEFENCE_IN_DEPTH

# bank-vendors: only the agentgateway may reach currency-converter. Only
# applied in single mode; in multi mode the lateral-hack inbound has no
# SPIFFE identity and this allow rule would never match.
if [[ "$APPLY_DEFENCE_IN_DEPTH" == "1" ]]; then
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
fi  # end APPLY_DEFENCE_IN_DEPTH for bank-vendors

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
OPEN_BROWSER=0 "$SCRIPT_DIR/port-forward.sh" 2>&1 | tail -1 | sed 's/^/    /' || true

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
log "Revert with: ./scripts/policies-off.sh"
