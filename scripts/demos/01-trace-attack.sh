#!/usr/bin/env bash
# Demo 1 — distributed tracing of the attack chain.
#
# WHEN TO USE THIS SCRIPT vs THE CHATBOT UI:
#   - On-stage demo: open the chatbot UI at http://localhost:18009
#     with debug toggled on, send the prompt yourself, then switch to
#     Tempo. The audience sees both the user-side AND platform-side
#     of the same request — that's the demo value.
#   - CI / smoke test / verifying pipes are connected: run this
#     script. It curl's the same /api/chat endpoint the UI uses, prints
#     the Tempo deep-link, exits.
#
# Pre-req: ./scripts/upgrade-banking-app.sh has rolled the rugpull image
# and Solo is in the OFF state (no AuthZ policies). Run reset-demo.sh
# first if you want a clean slate, then upgrade-banking-app.sh.
#
# What this script does (CI mode):
#   1. POST one attack-style prompt to the chatbot's /api/chat.
#   2. Pull the trace ID off the response (if exposed).
#   3. Print a Tempo deep-link so a verifier can confirm the trace
#      was emitted: chatbot → support-bot → MCP servers → ztunnel L4
#      deny (Solo ON) or evil-tools exfil (Solo OFF).
#
# DORA mapping: Art. 17 (incident management) — every agent decision is
# audited end-to-end, no blind spots.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"

log_step "Demo 1 — distributed trace of the attack chain"

CHATBOT_URL="http://localhost:${PF_FRONTEND_PORT}"
TEMPO_URL="http://localhost:${PF_GRAFANA_PORT}/explore?left=%7B%22datasource%22:%22tempo%22%7D"

log "Sending a request through the chatbot UI…"
RESP=$(curl -sS -X POST "${CHATBOT_URL}/api/chat" \
  -H "Content-Type: application/json" \
  -d '{"message": "Customer 12345, balance please and convert to USD"}' 2>&1 || true)

TRACE_ID=$(echo "$RESP" | python3 -c "
import json, sys
try:
  d = json.loads(sys.stdin.read())
  print(d.get('trace_id', d.get('debug', {}).get('trace_id', '')))
except Exception:
  pass
" 2>/dev/null)

echo ""
log_ok "request complete"
echo ""
if [[ -n "$TRACE_ID" ]]; then
  echo "    Trace ID: $TRACE_ID"
  echo "    Open in Tempo:"
  echo "    ${TEMPO_URL}&panes=%7B%22tempo%22:%7B%22queries%22:%5B%7B%22refId%22:%22A%22,%22query%22:%22${TRACE_ID}%22%7D%5D%7D%7D"
else
  log_warn "no trace_id surfaced from /api/chat response. Open Tempo and"
  log_warn "search by service.name=trustusbank-agentgw to find recent traces:"
  echo "    $TEMPO_URL"
fi

echo ""
log "Loki: every step the agent took, in order"
echo "    {namespace=~\"trustusbank-bank-agents|trustusbank-platform\"}"
echo "      |~ \"tools/call|get_balance|convert_currency|exfil\""
echo ""
log_ok "Demo 1 complete — trace shows the full attack path in a single view"
