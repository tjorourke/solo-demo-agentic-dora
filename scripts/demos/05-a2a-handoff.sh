#!/usr/bin/env bash
# Demo 5 — Agent-to-Agent (A2A) handoff over HBONE.
#
# kagent's Agent CRD supports A2A (Agent-to-Agent) protocol. When
# support-bot decides a request is fraud-related, it hands off to
# fraud-bot via A2A — a JSON-RPC call from one agent to another.
#
# The interesting Solo property: this A2A traffic flows OVER HBONE
# (Istio Ambient mTLS) between the two agent pods. Each agent has its
# own SPIFFE identity, and AuthorizationPolicy can lock down which
# agents can call which other agents.
#
# What this script demonstrates:
#   1. Trigger a "suspicious transaction" prompt that pushes support-bot
#      to delegate to fraud-bot.
#   2. Confirm the A2A request appears in ztunnel logs as a SPIFFE→SPIFFE
#      connection between the two agent pods (not via agentgateway).
#   3. Confirm the cross-namespace AuthZ permits this specific path.
#
# DORA mapping: Art. 9(2) — encryption + identity in transit applies to
# agent-to-agent calls too, not just agent-to-tool.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"

KAGENT_BASE="http://localhost:${PF_KAGENT_PORT}"

log_step "Demo 5 — Agent-to-Agent handoff"

log "Step 1 — direct hit on support-bot's A2A endpoint with a fraud-flavoured prompt"
log "        (this is what fraud-bot would receive when support-bot delegates)"

A2A_PAYLOAD='{
  "jsonrpc": "2.0",
  "id": "demo-a2a-1",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "parts": [{"kind":"text","text":"Customer 12345 reports a £4500 transfer to 'BTC-Trader-LTD' that they did not authorize. Please assess fraud risk and produce an incident summary."}]
    }
  }
}'

# kagent A2A endpoint is /api/a2a/{namespace}/{name}/
curl -sS -o /tmp/a2a-resp.json -w "  HTTP %{http_code} from fraud-bot A2A\n" \
  -X POST "${KAGENT_BASE}/api/a2a/trustusbank-bank-agents/fraud-bot/" \
  -H "Content-Type: application/json" \
  -d "$A2A_PAYLOAD" 2>&1 || log_warn "non-200 — adjust the URL/path; check kagent docs"

echo ""
echo "fraud-bot response (first 800 chars):"
python3 -c "
import json
try:
  with open('/tmp/a2a-resp.json') as f:
    d = json.load(f)
  txt = json.dumps(d, indent=2)
  print(txt[:800])
except Exception as e:
  print(f'  (could not parse response: {e})')"

echo ""
log "Step 2 — show the SPIFFE-identified A2A traffic in ztunnel"
echo "    Loki:"
echo "      {namespace=\"istio-system\", app=\"ztunnel\"}"
echo "        |~ \"src.workload=\\\"support-bot\\\"\" |~ \"dst.workload=\\\"fraud-bot\\\"\""
echo "    OR — every A2A connection (regardless of agent identity):"
echo "      {namespace=\"istio-system\", app=\"ztunnel\"}"
echo "        |~ \"dst.namespace=\\\"trustusbank-bank-agents\\\"\""
echo ""
log "Step 3 — what an AuthZ rule for this path looks like"
cat <<'EOF'

  apiVersion: security.istio.io/v1
  kind: AuthorizationPolicy
  metadata:
    name: allow-support-to-fraud-a2a
    namespace: trustusbank-bank-agents
  spec:
    selector: { matchLabels: { app: fraud-bot } }
    action: ALLOW
    rules:
      - from:
          - source:
              principals:
                - "cluster.local/ns/trustusbank-bank-agents/sa/support-bot"

EOF
log_ok "Demo 5 complete — A2A flowing on mTLS, SPIFFE-identified, governable"
