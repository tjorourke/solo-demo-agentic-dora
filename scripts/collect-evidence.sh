#!/usr/bin/env bash
# Collect every audit artefact referenced in §5 evidence-capture tasks.
# Output: ./evidence/phaseN/* — see plan §6 for DORA/NIS2 mapping.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

trap on_error ERR

# Phase 1 — HBONE / SPIFFE evidence (DORA Art. 9(2))
P1=$(evidence_dir 1)
log_step "Phase 1 evidence — HBONE + SPIFFE"
kubectl -n istio-system logs ds/ztunnel --tail=500 > "$P1/ztunnel.log" 2>&1 || true
kubectl get authorizationpolicy -A -o yaml > "$P1/authorization-policies.yaml" 2>&1 || true
grep -E 'spiffe://cluster.local/ns/' "$P1/ztunnel.log" > "$P1/spiffe-connections.txt" || true

# Phase 3 — agentregistry catalogue (DORA Art. 28)
P3=$(evidence_dir 3)
log_step "Phase 3 evidence — sub-outsourcing register"
if command -v arctl >/dev/null 2>&1; then
  arctl artifact list --format json > "$P3/sub-outsourcing-register.json" 2>&1 || true
else
  kubectl -n "$NS_PLATFORM" get artifacts.agentregistry.solo.io -o json \
    > "$P3/sub-outsourcing-register.json" 2>&1 || true
fi

# Phase 4 — MCP server traces
P4=$(evidence_dir 4)
log_step "Phase 4 evidence — MCP server traces"
kubectl -n "$NS_BANK_MCP" get pods -o yaml > "$P4/mcp-pods.yaml" 2>&1 || true

# Phase 5 — agentgateway access logs (DORA Art. 9 + 10)
P5=$(evidence_dir 5)
log_step "Phase 5 evidence — agentgateway access logs"
kubectl -n "$NS_PLATFORM" logs deploy/agentgateway --tail=1000 \
  > "$P5/access-log.jsonl" 2>&1 || true

# Phase 6 — agent decision traces (DORA Art. 17) — populated by test-agent-flow.sh
P6=$(evidence_dir 6)
log_step "Phase 6 evidence — agent decisions"
kubectl -n "$NS_BANK_AGENTS" get agents.kagent.dev -o yaml \
  > "$P6/agents.yaml" 2>&1 || true

# Phase 8 — incident report — populated by test-malicious-actor.sh
P8=$(evidence_dir 8)
log_step "Phase 8 evidence — bad actor incident"
if [[ ! -f "$P8/incident.json" ]]; then
  log_warn "no incident.json — run ./scripts/test-malicious-actor.sh first"
fi

log_ok "evidence collected under ${EVIDENCE_DIR}/"
ls -la "$EVIDENCE_DIR"
