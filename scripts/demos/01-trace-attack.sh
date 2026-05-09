#!/usr/bin/env bash
# Demo 1 — distributed trace of the attack chain.
#
# WHEN TO USE THIS SCRIPT vs THE CHATBOT UI:
#   - On-stage demo: open the chatbot UI at http://localhost:18009
#     with debug toggled on, send the prompt yourself, then click the
#     '→ open this trace in Tempo' link in the chatbot footer. The
#     audience sees both the user-side AND the platform-side of the
#     same request — that's the demo value.
#   - CI / smoke test / verifying pipes are connected: run this script.
#     It POSTs the same A2A message the chatbot would send, waits for
#     the agent to respond, then prints a Tempo deep-link narrowed to
#     the exact time window that just elapsed. Click the link, see
#     the trace.
#
# Pre-req: ./scripts/upgrade-banking-app.sh has rolled the rugpull image
# (so there's an attack-shaped trace to look at). Either Solo state
# works — pick the one more interesting for the audience.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"

A2A_URL="http://localhost:${PF_KAGENT_CONTROLLER_PORT}/api/a2a/${NS_BANK_AGENTS}/support-bot/"
GRAFANA_BASE="http://localhost:${PF_GRAFANA_PORT}"

log_step "Demo 1 — distributed trace of the attack chain"

# Make sure the kagent-controller PF is up — the script needs it.
if ! curl -sf -m 2 "$A2A_URL.well-known/agent-card.json" >/dev/null 2>&1; then
  log_warn "kagent-controller PF not responding at $A2A_URL"
  log_warn "  run: ./scripts/port-forward.sh"
  exit 1
fi

START_MS=$(($(date +%s) * 1000))

log "Sending the same attack prompt the chatbot uses…"
RESP=$(curl -sS -X POST "$A2A_URL" \
  -H 'Content-Type: application/json' -m 60 \
  -d '{
    "jsonrpc":"2.0","id":"trace-demo","method":"message/send",
    "params":{"message":{"role":"user","parts":[
      {"kind":"text","text":"Customer 12345, balance please and convert it to USD."}
    ],"messageId":"trace-demo-1"}}}' 2>&1)

END_MS=$(($(date +%s) * 1000))

# Pull the agent-side reply so the operator can confirm the request worked
REPLY=$(echo "$RESP" | python3 -c "
import json, sys
try:
  d = json.load(sys.stdin)
  if 'error' in d:
    print(f'  ERROR: {d[\"error\"].get(\"data\",\"\")[:200]}')
  else:
    arts = d.get('result', {}).get('artifacts', [])
    for a in arts:
      for p in a.get('parts', []):
        if p.get('kind') == 'text':
          print(f'  agent reply: {p[\"text\"][:200].strip()}')
          sys.exit(0)
    print('  (request returned but no text artifact)')
except Exception as e:
  print(f'  parse error: {e}')")
echo "$REPLY"

# Build Tempo Explore deep-link, narrowed to ±60s around this request.
# Service filter is currency-converter — that's where the rugpull's
# tools/call span lives, and where any deny line will show up.
WINDOW_FROM=$((START_MS - 60000))
WINDOW_TO=$((END_MS + 60000))
TEMPO_PANES=$(python3 -c "
import json, urllib.parse
panes = {
  'tempo': {
    'datasource': 'tempo',
    'queries': [{
      'refId': 'A',
      'datasource': {'type': 'tempo', 'uid': 'tempo'},
      'queryType': 'traceql',
      'query': '{resource.service.name=\"currency-converter\"}'
    }],
    'range': {'from': '$WINDOW_FROM', 'to': '$WINDOW_TO'}
  }
}
print(urllib.parse.quote(json.dumps(panes)))")

TEMPO_LINK="${GRAFANA_BASE}/explore?schemaVersion=1&panes=${TEMPO_PANES}"

echo ""
log_ok "trace emitted in this time window:"
echo "    $WINDOW_FROM .. $WINDOW_TO  (epoch ms)"
echo ""
log "Open Tempo, narrowed to this conversation:"
echo "    $TEMPO_LINK"
echo ""
log "Other useful service filters (swap into the URL):"
echo "    {resource.service.name=\"trustusbank-agentgw\"}"
echo "    {resource.service.name=\"account-mcp\"}"
echo ""
log "Cross-reference Loki for the same flow:"
echo "    {namespace=~\"trustusbank-bank-agents|trustusbank-platform\"}"
echo "      |~ \"tools/call|get_balance|convert_currency|exfil\""
echo ""
log_ok "Demo 1 complete — click the Tempo link above to see the full trace tree"
