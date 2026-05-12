#!/usr/bin/env bash
# Phase 6 — kagent install (Solo Enterprise variant), ModelConfig, RemoteMCPServer, 3 Agents.
#
# Installs Solo Enterprise for kagent (kagent-enterprise) instead of the
# OSS kagent.dev chart so the demo can showcase the Enterprise UI. The
# kagent.dev/v1alpha2 Agent / ModelConfig / RemoteMCPServer CRDs are the
# same on both sides; Enterprise just adds the policy.kagent-enterprise.
# solo.io group plus the management UI binary.
#
# Three notable diffs from a clean Enterprise install:
#
# 1. Mock OIDC. The Enterprise controller auto-points its OIDC issuer at
#    http://solo-enterprise-ui.<ns>.svc.cluster.local:5556 (the Solo
#    management plane). We're not running that plane on the demo, so a
#    tiny nginx ConfigMap serves a static /.well-known/openid-configuration
#    discovery doc just to satisfy startup. See manifests/kagent-enterprise/
#    mock-oidc.yaml.
#
# 2. License key is a 12-char dummy. The chart accepts any non-empty value
#    in dev mode; only a warning is logged.
#
# 3. Nginx upstream patch. The kagent-ui pod's nginx config from the chart
#    points /api/ to 127.0.0.1:8083, but the kagent-enterprise-controller
#    runs in a separate pod. Patched post-install to point at the actual
#    service.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.4.0}"
KAGENT_ENT_REGISTRY="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts"

log_step "6.1 — mock OIDC discovery endpoint (satisfies controller startup)"
kubectl create ns "$NS_PLATFORM" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl_apply "$REPO_ROOT/manifests/kagent-enterprise/mock-oidc.yaml"
kubectl -n "$NS_PLATFORM" rollout status deploy/solo-enterprise-ui --timeout=60s | tail -1

log_step "6.2 — kagent-enterprise-crds $KAGENT_ENT_VERSION"
helm_upgrade_install kagent-enterprise-crds "$KAGENT_ENT_REGISTRY/kagent-enterprise-crds" \
  --version "$KAGENT_ENT_VERSION" \
  -n "$NS_PLATFORM"

log_step "6.3 — kagent-enterprise $KAGENT_ENT_VERSION (slim values)"
helm_upgrade_install kagent-enterprise "$KAGENT_ENT_REGISTRY/kagent-enterprise" \
  --version "$KAGENT_ENT_VERSION" \
  -n "$NS_PLATFORM" \
  -f "$REPO_ROOT/manifests/kagent-enterprise/values-slim.yaml"
wait_for_pods_ready "$NS_PLATFORM" "app.kubernetes.io/name=kagent" 300s

log_step "6.3b — patch UI nginx upstream → real controller service"
# The chart's bundled nginx config in the UI pod hard-codes the backend
# upstream to 127.0.0.1:8083, which would be correct only if the controller
# ran inside the UI pod (it doesn't). Without this, /api/auth/* and
# /api/agents requests from the UI return 502.
kubectl -n "$NS_PLATFORM" get cm kagent-ui-config -o yaml | \
  sed 's|server 127\.0\.0\.1:8083;|server kagent-controller.'"$NS_PLATFORM"'.svc.cluster.local:8083;|' | \
  kubectl apply -f - >/dev/null
kubectl -n "$NS_PLATFORM" rollout restart deploy/kagent-ui
kubectl -n "$NS_PLATFORM" rollout status deploy/kagent-ui --timeout=90s | tail -1

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
