#!/usr/bin/env bash
# Deploy Solo's protection layers. The CLIMAX of the demo:
# the attack just succeeded, you run this, and now the same attack fails.
#
# What this applies:
#   1. Istio AuthorizationPolicies on every workload namespace, using
#      SPIFFE-principal source matching (NOT namespace-based — that
#      breaks under supply-chain compromise).
#   2. The deny-egress-to-attacker policy on external-attacker (this is
#      what stops the lateral exfil from evil-tools to the C2 server).
#   3. (Optional) refreshes port-forwards.
#
# Run ./scripts/solo-off.sh to revert to bare-K8s state.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

log_step "Deploying Solo's protection layers"

log "1/2 — Istio AuthorizationPolicies (SPIFFE-principal allow-list)"
kubectl_apply "$MANIFESTS_DIR/phase01-ambient/deny-all-cross-ns.yaml"

# bank-mcp: only the legitimate agents and data-plane proxies (by SA)
# may reach the MCP servers. Wherever the attacker drops their pod, its
# SA won't be in this list.
kubectl apply -f - <<'EOF' 2>&1 | sed 's/^/    /'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-agents-to-mcp
  namespace: trustusbank-bank-mcp
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/trustusbank-bank-agents/sa/support-bot"
              - "cluster.local/ns/trustusbank-bank-agents/sa/fraud-bot"
              - "cluster.local/ns/trustusbank-bank-agents/sa/triage-bot"
              - "cluster.local/ns/trustusbank-platform/sa/trustusbank-agentgw"
              # Ambient waypoints sit in the source path between caller
              # and target; from ztunnel's view at MCP-pod inbound, the
              # source identity is the bank-mcp namespace's waypoint SA,
              # not the original agent. Without this, MCP calls 503 with
              # "allow policies exist, but none allowed".
              - "cluster.local/ns/trustusbank-bank-mcp/sa/waypoint"
EOF

# bank-agents: chatbot + kagent UI may invoke agents; agents may A2A
# each other.
kubectl apply -f - <<'EOF' 2>&1 | sed 's/^/    /'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-platform-to-agents
  namespace: trustusbank-bank-agents
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/trustusbank-platform/sa/kagent-ui"
              - "cluster.local/ns/trustusbank-platform/sa/kagent-controller"
              - "cluster.local/ns/trustusbank-bank-frontend/sa/chatbot"
              - "cluster.local/ns/trustusbank-bank-agents/sa/support-bot"
              - "cluster.local/ns/trustusbank-bank-agents/sa/fraud-bot"
              - "cluster.local/ns/trustusbank-bank-agents/sa/triage-bot"
              # Same Ambient-with-waypoint quirk as in bank-mcp above.
              # The bank-agents waypoint sits in front of the agent
              # pods, so from ztunnel's view of the inbound to support-bot
              # / fraud-bot / triage-bot, the source SA is the waypoint,
              # not the original caller. Without this entry, A2A calls
              # (and any chatbot→agent route that transits the waypoint)
              # return 503 'upstream connect error'.
              - "cluster.local/ns/trustusbank-bank-agents/sa/waypoint"
EOF

# bank-evil: only the agentgateway may proxy to evil-tools (so support-bot
# can still call convert_currency through the gateway). Pods inside
# bank-evil cannot themselves reach into bank-mcp because their SAs
# aren't in the allow-agents-to-mcp policy above.
kubectl apply -f - <<'EOF' 2>&1 | sed 's/^/    /'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-gw-to-evil
  namespace: trustusbank-bank-evil
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/trustusbank-platform/sa/trustusbank-agentgw"
EOF

log "2/2 — block egress to mock-attacker (the C2 endpoint)"
kubectl_apply "$MANIFESTS_DIR/phase01-attacker/deny-egress-to-attacker.yaml"

log "refreshing port-forwards"
"$SCRIPT_DIR/port-forward.sh" 2>&1 | tail -1 | sed 's/^/    /' || true

echo ""
log_ok "Solo is now ENFORCING."
log ""
log "What just turned on:"
log "  • Istio AuthZ — every connection identity-checked at L4"
log "  • Default-deny on bank-mcp / bank-agents / bank-evil"
log "  • Deny egress from any bank namespace → external-attacker"
log ""
log "Re-run the attack. The chat will look the same; the breach won't happen."
log "  ./scripts/upgrade-banking-app.sh"
log "  (in chatbot) Customer 12345 — balance please, and convert to USD"
log "  kubectl -n external-attacker logs deploy/mock-attacker"
log ""
log "Revert with: ./scripts/solo-off.sh"
