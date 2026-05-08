#!/usr/bin/env bash
# End-to-end happy-path test: customer support flow.
# Sends a prompt to support-bot; expects a 3-agent trace (support → fraud → triage)
# to appear in Tempo.
# Emits ./evidence/phase6/decision-trace.json

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

trap on_error ERR

EVIDENCE=$(evidence_dir 6)

PROMPT="${PROMPT:-Hi, I am customer 12345. Please check my balance and recent transactions. There is one I do not recognise — can you flag it and open a ticket?}"

log_step "Sending prompt to support-bot via kagent A2A endpoint"

A2A_URL="http://localhost:${PF_KAGENT_PORT}/api/a2a/${NS_BANK_AGENTS}/support-bot/v1/messages"
log "POST $A2A_URL"

curl -sS -X POST "$A2A_URL" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c 'import json,sys,os; print(json.dumps({"role":"user","parts":[{"text": os.environ["PROMPT"]}]}))')" \
  > "$EVIDENCE/agent-response.json" 2>&1 || log_warn "A2A call failed; capturing stderr"

cat "$EVIDENCE/agent-response.json" 2>/dev/null | head -40 || true

log "Querying Tempo for the trace"
sleep 3
TRACE_URL="http://localhost:${PF_TEMPO_PORT}/api/search?tags=agent.name%3Dsupport-bot&limit=1"
curl -sS "$TRACE_URL" > "$EVIDENCE/tempo-search.json" || true

TRACE_ID=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    traces = d.get("traces") or d.get("data") or []
    if traces:
        print(traces[0].get("traceID") or traces[0].get("traceId") or "")
except Exception:
    print("")
' "$EVIDENCE/tempo-search.json" 2>/dev/null || echo "")

if [[ -n "$TRACE_ID" ]]; then
  log_ok "trace ID: $TRACE_ID"
  curl -sS "http://localhost:${PF_TEMPO_PORT}/api/traces/${TRACE_ID}" \
    > "$EVIDENCE/decision-trace.json"
  log "decision trace saved to $EVIDENCE/decision-trace.json"
  log "Open in Grafana: http://localhost:${PF_GRAFANA_PORT}/explore?left=%7B%22datasource%22:%22tempo%22,%22queries%22:%5B%7B%22query%22:%22${TRACE_ID}%22%7D%5D%7D"
else
  log_warn "no trace yet — Tempo ingestion can lag. Try again in a few seconds."
fi
