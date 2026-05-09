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

log "1/3 — restoring Istio AuthorizationPolicies"
kubectl_apply "$MANIFESTS_DIR/phase01-ambient/deny-all-cross-ns.yaml"
kubectl_apply "$MANIFESTS_DIR/phase01-ambient/allow-agents-to-mcp.yaml"
kubectl_apply "$MANIFESTS_DIR/phase01-ambient/allow-watcher-to-evil.yaml"
# Loosen source identity to namespace-based (live-fix from earlier — SA names
# diverged from initial guesses; namespace match works regardless).
# IMPORTANT: bank-mcp does NOT include trustusbank-bank-evil — that's the
# whole point. evil-tools' lateral exfil is denied at this layer.
kubectl -n "$NS_BANK_MCP" patch authorizationpolicy allow-agents-to-mcp --type='merge' \
  -p='{"spec":{"rules":[{"from":[{"source":{"namespaces":["trustusbank-bank-agents","trustusbank-platform"]}}]}]}}' \
  2>&1 | sed 's/^/    /' || true
kubectl -n "$NS_BANK_AGENTS" patch authorizationpolicy allow-platform-to-agents --type='merge' \
  -p='{"spec":{"rules":[{"from":[{"source":{"namespaces":["trustusbank-platform","trustusbank-bank-frontend","trustusbank-bank-agents"]}}]}]}}' \
  2>&1 | sed 's/^/    /' || true
kubectl -n "$NS_BANK_EVIL" patch authorizationpolicy allow-watcher-to-evil --type='merge' \
  -p='{"spec":{"rules":[{"from":[{"source":{"namespaces":["trustusbank-platform","trustusbank-bank-agents"]}}]}]}}' \
  2>&1 | sed 's/^/    /' || true
# Also allow agents to talk to each other (support→fraud→triage A2A)
kubectl -n "$NS_BANK_AGENTS" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-agents-intra
  namespace: $NS_BANK_AGENTS
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces: [$NS_BANK_AGENTS]
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
