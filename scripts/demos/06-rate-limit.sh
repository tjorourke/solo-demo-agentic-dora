#!/usr/bin/env bash
# Demo 6 — rate limiting at agentgateway via native AgentgatewayPolicy.
#
# Applies a tight 5-req/min policy on top of the existing 100/min, then
# sends 30 sequential requests and counts how many got 429. Verified
# end-to-end during build: 10×200 + 20×429.
#
# What this defends against:
#   - A bug-looped agent calling a tool in a tight loop (cost runaway)
#   - A compromised agent attempting DOS before AuthZ catches it
#   - LLM hallucinations that cause infinite tool-call retry chains

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"

MANIFEST="$REPO_ROOT/manifests/demos/06-rate-limit.yaml"

log_step "Demo 6 — agentgateway rate limit (5 req/min for the demo)"

log "Step 1 — apply the AgentgatewayPolicy"
kubectl apply -f "$MANIFEST" 2>&1 | tail -2
sleep 8  # let agentgateway pick up the new policy

log "Step 2 — fire 30 sequential MCP initialize requests; count the 429s"
TOTAL=30
LOG_TMP=$(mktemp)
kubectl run -n default tmpcurl-burst-$$ --rm -i --restart=Never --image=curlimages/curl:latest -- sh -c "
for i in \$(seq 1 $TOTAL); do
  curl -s -o /dev/null -w '%{http_code}\n' \
    -X POST http://trustusbank-agentgw.trustusbank-platform.svc.cluster.local:8080/mcp/account \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"d\",\"version\":\"1\"}}}' --max-time 1
done
" 2>&1 | grep -v "pod \"" | grep -v "deleted from" | grep -E "^[0-9]+$" > "$LOG_TMP"

STATUS_429=$(grep -c "^429$" "$LOG_TMP" 2>/dev/null || echo 0)
STATUS_200=$(grep -c "^200$" "$LOG_TMP" 2>/dev/null || echo 0)
rm -f "$LOG_TMP"

echo ""
echo "  Out of $TOTAL requests:"
echo "    HTTP 200 (allowed):    $STATUS_200"
echo "    HTTP 429 (rate-limit): $STATUS_429"

if [[ "$STATUS_429" -gt 0 ]]; then
  log_ok "rate limit firing — agentgateway returned 429 once budget exhausted"
else
  log_warn "no 429s — check the policy attached:"
  log_warn "  kubectl -n trustusbank-platform get agentgatewaypolicy agentgw-rate-limit-demo -o yaml"
fi

echo ""
log "Token-budget variant for LLM cost control:"
echo "    spec.traffic.rateLimit.local[0].tokens: 50000   # tokens/min"
echo "    (counts both input + output tokens; charges to bucket on completion)"
echo ""
log "To remove the demo policy:"
echo "    kubectl -n trustusbank-platform delete agentgatewaypolicy agentgw-rate-limit-demo"
log_ok "Demo 6 complete"
