#!/usr/bin/env bash
# Phase 6 — kagent install, ModelConfig, RemoteMCPServer, 3 Agents.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

helm_repo_add_once kagent https://kagent-dev.github.io/kagent

log_step "6.1 — kagent CRDs"
helm_upgrade_install kagent-crds kagent/kagent-crds \
  -n "$NS_PLATFORM"

log_step "6.2 — kagent controller"
helm_upgrade_install kagent kagent/kagent \
  -n "$NS_PLATFORM"
wait_for_pods_ready "$NS_PLATFORM" "app.kubernetes.io/name=kagent" 300s

log_step "6.3 — Anthropic API key Secret"
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY not set"
kubectl -n "$NS_BANK_AGENTS" create secret generic kagent-anthropic \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

log_step "6.4 — ModelConfig"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/modelconfig.yaml"

log_step "6.5 — RemoteMCPServer (point at agentgateway, NOT MCP servers directly)"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/remote-mcp-servers.yaml"

log_step "6.6-6.8 — Agent CRDs"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/agent-support-bot.yaml"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/agent-fraud-bot.yaml"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/agent-triage-bot.yaml"

log_step "6.9 — verifying agents"
kubectl -n "$NS_BANK_AGENTS" wait --for=condition=Ready agents.kagent.dev --all --timeout=300s || \
  log_warn "agents not all Ready — check kubectl describe agents -n $NS_BANK_AGENTS"

log_step "6.10 — agent telemetry → OTel"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/telemetry.yaml"

log_step "6.11 — evidence (DORA Art. 17)"
P6=$(evidence_dir 6)
kubectl -n "$NS_BANK_AGENTS" get agents.kagent.dev -o yaml > "$P6/agents.yaml" || true

log_ok "Phase 6 (kagent) complete"
