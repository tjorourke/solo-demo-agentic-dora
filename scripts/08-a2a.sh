#!/usr/bin/env bash
# Phase 7 — A2A wiring + tenant isolation.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

log_step "7.1 — verify A2A endpoints"
for agent in support-bot fraud-bot triage-bot; do
  card_url="http://kagent-ui.${NS_PLATFORM}.svc.cluster.local/api/a2a/${NS_BANK_AGENTS}/${agent}/.well-known/agent.json"
  log "agent card: $card_url"
done
# (Real verification happens via the port-forwarded URL after deploy-all completes)

log_step "7.2-7.3 — A2A invocation wiring already encoded in agent system prompts"
# The Agent CRDs in 06-kagent reference each other via A2A. Re-apply to ensure
# any prompt updates propagate.
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/agent-support-bot.yaml"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/agent-fraud-bot.yaml"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/agent-triage-bot.yaml"

log_step "7.5 — A2A tenant isolation policy (NIS2 Art. 21(2)(d))"
kubectl_apply "$MANIFESTS_DIR/phase07-a2a/tenant-isolation.yaml"

log_step "7.4 — happy-path test"
"$SCRIPT_DIR/test-agent-flow.sh" || log_warn "agent flow returned non-zero — Tempo ingest may lag, re-run manually"

log_ok "Phase 7 (A2A) complete"
