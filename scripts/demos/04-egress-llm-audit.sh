#!/usr/bin/env bash
# Demo 4 — egress LLM gateway with prompt/response audit.
#
# Deploys an in-cluster reverse proxy that sits between the bank's
# agents and api.anthropic.com. Every prompt that the agents send to
# the model goes through it; every response the model returns goes
# through it; both are captured in Loki.
#
# What the audience sees:
#   1. Deployment of the gateway (Caddy reverse proxy) — 5 sec.
#   2. A test request flowing through it — 10 sec.
#   3. The Loki query that surfaces the captured prompts.
#
# Production-hardening this: replace Caddy with agentgateway's AI
# Backend, add prompt-injection detection (commercial agentgateway
# feature), DLP redaction. The OSS version captures the full flow;
# Solo Platform productizes the inspection.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"

MANIFEST="$REPO_ROOT/manifests/demos/04-egress-llm-gateway.yaml"

log_step "Demo 4 — egress LLM gateway"

log "Step 1 — deploy"
kubectl apply -f "$MANIFEST" 2>&1 | tail -4
echo ""
until kubectl -n trustusbank-egress get pod -l app=egress-llm-gw -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q "true"; do sleep 3; done
log_ok "egress-llm-gw is ready"

log "Step 2 — send a test prompt through the gateway"
kubectl run -n default tmpcurl-egress --rm -i --restart=Never --image=curlimages/curl:latest -- \
  curl -sS -o /dev/null -w "  HTTP %{http_code} via egress-llm-gw\n" \
  -X POST http://egress-llm-gw.trustusbank-egress.svc.cluster.local:8080/v1/messages \
  -H "x-api-key: ${ANTHROPIC_API_KEY:-test-key}" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-3-5-haiku-20241022","max_tokens":32,"messages":[{"role":"user","content":"reply with the word OK"}]}' \
  2>&1 | grep -v "pod \"" | grep -v "deleted from"

echo ""
log "Step 3 — pull the prompt from Loki (the gateway logged it)"
echo "    Loki query:"
echo "      {namespace=\"trustusbank-egress\", app=\"egress-llm-gw\"}"
echo "    Open in Grafana:"
echo "      http://localhost:${PF_GRAFANA_PORT}/explore?left=%7B%22datasource%22:%22loki%22,%22queries%22:%5B%7B%22expr%22:%22%7Bnamespace%3D%5C%22trustusbank-egress%5C%22%7D%22%7D%5D%7D"
echo ""
log "To repoint kagent agents at this gateway (production move):"
echo "    edit manifests/phase06-kagent/modelconfig.yaml"
echo "    set spec.endpoint: http://egress-llm-gw.trustusbank-egress.svc.cluster.local:8080"
echo ""
log_ok "Demo 4 complete — every outbound LLM call is now auditable"
