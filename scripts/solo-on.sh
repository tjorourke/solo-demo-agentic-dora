#!/usr/bin/env bash
# Restore the Solo platform protection layers. Used in Act 2 of the demo
# after running ./scripts/solo-off.sh.
#
# What this re-applies:
#   1. Istio AuthorizationPolicies — default deny on each workload
#      namespace + explicit allow rules for the legitimate flows:
#        agents → bank-mcp                (support-bot/fraud-bot/triage-bot SAs)
#        platform → bank-agents           (kagent-ui can call agent A2A)
#        platform/agents → bank-evil      (only the watcher + gateway)
#      Lateral exfil from bank-evil → bank-mcp is now denied at L4.
#   2. agentgateway tool-allowlist policies on each HTTPRoute (CEL on
#      mcp.tool.name + agent identity).
#   3. digest-watcher restored to 1 replica.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

log_step "Solo ON — restoring platform protection layers"

log "1/3 — restoring Istio AuthorizationPolicies (SA-based, not namespace-based)"
# IMPORTANT: this version uses SPIFFE principal matching, NOT namespace
# matching. Namespace-based rules break the moment a malicious pod lands
# inside an "allowed" namespace (the supply-chain attack model). With
# SA-based principals, only the specific workloads we trust can reach
# the data planes — wherever the attacker drops their malicious pod.
kubectl_apply "$MANIFESTS_DIR/phase01-ambient/deny-all-cross-ns.yaml"

# bank-mcp: only the legitimate agents (by SA) and the legitimate
# data-plane proxies (by SA) may reach the MCP servers. evil-tools'
# SA is NOT here — wherever it gets deployed.
kubectl apply -f - <<'EOF'
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
              # The three legitimate AI agents
              - "cluster.local/ns/trustusbank-bank-agents/sa/support-bot"
              - "cluster.local/ns/trustusbank-bank-agents/sa/fraud-bot"
              - "cluster.local/ns/trustusbank-bank-agents/sa/triage-bot"
              # The data plane (agentgateway forwards MCP traffic on
              # behalf of agents). The data-plane proxy's SA is what
              # appears on the wire when traffic comes via the gateway.
              - "cluster.local/ns/trustusbank-platform/sa/trustusbank-agentgw"
              # The audit canary (digest-watcher polls tools/list)
              - "cluster.local/ns/trustusbank-platform/sa/digest-watcher"
EOF

# bank-agents: only the chatbot (frontend) and the kagent-ui (the A2A
# entrypoint Solo runs) may invoke agents. Plus agents can talk to each
# other for A2A handoff.
kubectl apply -f - <<'EOF'
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
              # agents can A2A-call each other
              - "cluster.local/ns/trustusbank-bank-agents/sa/support-bot"
              - "cluster.local/ns/trustusbank-bank-agents/sa/fraud-bot"
              - "cluster.local/ns/trustusbank-bank-agents/sa/triage-bot"
EOF

# bank-evil: only the watcher and the gateway can reach evil-tools
# (so we can fingerprint it and proxy MCP calls to it). Pods in
# trustusbank-bank-evil cannot make outbound calls into bank-mcp
# because their SAs don't appear in the allow-agents-to-mcp policy.
kubectl apply -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-watcher-to-evil
  namespace: trustusbank-bank-evil
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/trustusbank-platform/sa/digest-watcher"
              - "cluster.local/ns/trustusbank-platform/sa/trustusbank-agentgw"
EOF

log "2/3 — agentgateway tool-allowlist (DEMO: log-only, audit trail in Loki)"
# The full L7 allowlist requires JWT auth wired up so per-agent identity is
# available in CEL (jwt.sub). For the demo we keep agentgateway as the
# always-on audit layer (every MCP call lands in Loki via promtail), and rely
# on Istio AuthZ for enforcement. To enable strict L7 allowlisting:
#   kubectl apply -f manifests/phase05-agentgateway/tool-allowlist.yaml
# (after re-enabling the JWT validation policy and refreshing JWT secrets).
kubectl -n "$NS_PLATFORM" delete agentgatewaypolicy \
  account-mcp-allowlist transaction-mcp-allowlist ticket-mcp-allowlist \
  --ignore-not-found 2>&1 | sed 's/^/    /' || true

log "3/3 — restoring digest-watcher (and waiting for it to be ready)"
kubectl -n "$NS_PLATFORM" scale deploy/digest-watcher --replicas=1 2>&1 | sed 's/^/    /' || true
kubectl -n "$NS_PLATFORM" rollout status deploy/digest-watcher --timeout=120s 2>&1 | sed 's/^/    /' || true

log "refreshing port-forwards (new pod IPs after restart)"
"$SCRIPT_DIR/port-forward.sh" 2>&1 | tail -1 | sed 's/^/    /' || true

log_ok "TrustUsBank is now PROTECTED. Lateral exfil will be denied at the network layer."
log "Try the same attack again: ./scripts/test-malicious-actor.sh --vector rugpull --variant aggressive"
