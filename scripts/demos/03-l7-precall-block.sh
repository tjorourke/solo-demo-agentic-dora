#!/usr/bin/env bash
# Demo 3 — L7 pre-call blocking. agentgateway refuses to forward
# tool calls to /mcp/currency-converter. The agent gets a 403 BEFORE any PII is
# passed to the malicious tool.
#
# Differs from the main demo's L4 approach (which lets the tool call
# happen, then catches the lateral exfil). This one catches earlier.
#
# Run order:
#   1. ./scripts/reset-demo.sh                       — clean slate
#   2. ./scripts/upgrade-banking-app.sh              — rugpull the vendor
#   3. ./scripts/demos/03-l7-precall-block.sh        — apply L7 deny
#   4. (test in chatbot — convert to USD prompt)
# After this, policies-on.sh's L4 policies layer ON TOP for defense-in-
# depth.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"

POLICY="$REPO_ROOT/manifests/demos/03-l7-precall-block.yaml"

log_step "Demo 3 — L7 pre-call block"

log "Apply the L7 deny policy"
kubectl apply -f "$POLICY" 2>&1 | tail -2

log "Verify it's accepted by agentgateway's selector"
kubectl -n trustusbank-platform get authorizationpolicy deny-mcp-vendor-route-l7 -o yaml \
  | grep -A 5 selector

echo ""
log "Test — try a tools/call from inside the cluster"
kubectl run -n default tmpcurl-l7 --rm -i --restart=Never --image=curlimages/curl:latest -- \
  curl -sS -o /dev/null -w "  HTTP %{http_code} from agentgateway /mcp/currency-converter\n" \
  -X POST http://trustusbank-agentgw.trustusbank-platform.svc.cluster.local:8080/mcp/currency-converter \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>&1 | grep -v "pod \"" | grep -v "deleted from"

echo ""
log "Expected: HTTP 403. The agent never receives the tool list, so the"
log "malicious description never reaches the LLM. PII never leaves the"
log "model context as a tool argument."
echo ""
log_ok "Demo 3 complete — pre-call block in place"
echo ""
log "To layer L4 on top:  ./scripts/policies-on.sh"
log "To remove this L7:   kubectl -n trustusbank-platform delete authorizationpolicy deny-mcp-vendor-route-l7"
