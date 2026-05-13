#!/usr/bin/env bash
# Phase 6 — kagent install (Solo Enterprise variant), dex IdP,
# oauth2-proxy front-door, ModelConfig, RemoteMCPServer, 3 Agents.
#
# Installs Solo Enterprise for kagent (kagent-enterprise) instead of
# the OSS kagent.dev chart so the demo can showcase the Enterprise UI.
# The kagent.dev/v1alpha2 Agent / ModelConfig / RemoteMCPServer CRDs are
# the same on both sides; Enterprise just adds the
# policy.kagent-enterprise.solo.io group plus the management UI binary.
#
# Four notable diffs from a vanilla single-cluster Enterprise install:
#
# 1. dex as OIDC IdP. The Enterprise controller requires a real OIDC
#    issuer; the chart auto-points it at the Solo management plane (not
#    deployed here). dex serves the issuer URL with a single static user
#    (admin@kagent.local / admin). Issuer URL uses host.docker.internal
#    so the same URL works from BOTH in-cluster pods (kind's CoreDNS
#    resolves it to the Docker host IP) AND the user's browser (which
#    resolves it via /etc/hosts — see ../docs/index.html "Install
#    prerequisites" for the one-line /etc/hosts edit).
#
# 2. oauth2-proxy in front of kagent-ui. The kagent UI's "Sign in with
#    SSO" button is hardcoded to /oauth2/start, expecting an oauth2-proxy
#    sidecar to handle the OIDC dance. Not bundled in the Enterprise
#    chart, so installed separately and stood in front of kagent-ui.
#
# 3. License key is a 12-char dummy. The chart accepts any non-empty
#    value in dev mode; only a warning is logged.
#
# 4. Nginx upstream patch. The kagent-ui pod's nginx config from the
#    chart points /api/ to 127.0.0.1:8083, but the
#    kagent-enterprise-controller runs in a separate pod. Patched
#    post-install to point at the actual service.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

KAGENT_ENT_VERSION="${KAGENT_ENT_VERSION:-0.4.0}"
KAGENT_ENT_REGISTRY="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts"

log_step "6.0 — install prerequisite check: host.docker.internal in /etc/hosts"
if ! grep -q host.docker.internal /etc/hosts 2>/dev/null; then
  log_warn "host.docker.internal is NOT in /etc/hosts."
  log_warn "The kagent Enterprise UI login flow won't work without it."
  log_warn "Add this line to /etc/hosts (requires sudo):"
  log_warn ""
  log_warn "  echo '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts"
  log_warn ""
  log_warn "Then re-run this script. Continuing anyway — the controller will"
  log_warn "boot but in-browser SSO redirect will fail with DNS_PROBE_FINISHED_NXDOMAIN."
fi

log_step "6.1 — dex IdP (issues OIDC tokens for kagent Enterprise UI)"
helm repo add dex https://charts.dexidp.io >/dev/null 2>&1 || true
helm repo update dex >/dev/null 2>&1
kubectl create ns "$NS_PLATFORM" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm_upgrade_install dex dex/dex \
  --version 0.24.0 \
  -n "$NS_PLATFORM" \
  -f "$REPO_ROOT/manifests/dex/values.yaml"
kubectl -n "$NS_PLATFORM" rollout status deploy/dex --timeout=120s | tail -1

log_step "6.2 — kagent OIDC client secret (must match dex's static client)"
# Extract the static client's secret from the rendered dex Secret so the
# value is guaranteed to match. The dex Secret is created by the helm
# chart from the values file (single source of truth).
DEX_CLIENT_SECRET=$(kubectl -n "$NS_PLATFORM" get secret dex -o jsonpath='{.data.config\.yaml}' | \
  base64 -d | awk '/^staticClients:/{f=1} f && /secret:/{print $2; exit}')
[[ -n "$DEX_CLIENT_SECRET" ]] || die "could not extract dex client secret"
kubectl -n "$NS_PLATFORM" create secret generic kagent-enterprise-oidc-secret \
  --from-literal=clientSecret="$DEX_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

log_step "6.3 — kagent-enterprise-crds $KAGENT_ENT_VERSION"
helm_upgrade_install kagent-enterprise-crds "$KAGENT_ENT_REGISTRY/kagent-enterprise-crds" \
  --version "$KAGENT_ENT_VERSION" \
  -n "$NS_PLATFORM"

log_step "6.4 — kagent-enterprise $KAGENT_ENT_VERSION (slim values + dex OIDC)"
helm_upgrade_install kagent-enterprise "$KAGENT_ENT_REGISTRY/kagent-enterprise" \
  --version "$KAGENT_ENT_VERSION" \
  -n "$NS_PLATFORM" \
  -f "$REPO_ROOT/manifests/kagent-enterprise/values-slim.yaml"
# Enterprise chart labels pods app.kubernetes.io/name=kagent-enterprise
# (the OSS chart used "kagent"). Wait for the controller specifically —
# UI + postgres come up at the same time. Controller racing postgres on
# first start is normal; let it self-heal via CrashLoopBackOff.
wait_for_pods_ready "$NS_PLATFORM" "app.kubernetes.io/name=kagent-enterprise,app.kubernetes.io/component=controller" 300s

log_step "6.4b — patch UI nginx upstream → real controller service"
# The chart's bundled nginx config in the UI pod hard-codes the backend
# upstream to 127.0.0.1:8083, which would be correct only if the
# controller ran inside the UI pod (it doesn't). Without this, /api/...
# requests from the UI return 502.
kubectl -n "$NS_PLATFORM" get cm kagent-ui-config -o yaml | \
  sed 's|server 127\.0\.0\.1:8083;|server kagent-controller.'"$NS_PLATFORM"'.svc.cluster.local:8083;|' | \
  kubectl apply -f - >/dev/null
kubectl -n "$NS_PLATFORM" rollout restart deploy/kagent-ui
kubectl -n "$NS_PLATFORM" rollout status deploy/kagent-ui --timeout=90s | tail -1

log_step "6.5 — oauth2-proxy (front-door for kagent-ui, handles /oauth2/start)"
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests >/dev/null 2>&1 || true
helm repo update oauth2-proxy >/dev/null 2>&1
# Render the values file with the dex client secret + a fresh cookie secret
# (re-use the existing cookie secret if oauth2-proxy is already installed
# so users don't get logged out on re-deploy).
COOKIE_SECRET=$(kubectl -n "$NS_PLATFORM" get secret oauth2-proxy -o jsonpath='{.data.cookie-secret}' 2>/dev/null | base64 -d || true)
# Must be exactly 16/24/32 bytes for AES. `openssl rand -base64 32` yields
# 44 chars (base64 of 32 raw bytes) which oauth2-proxy rejects. Use hex
# instead: 16 random bytes = 32 hex chars = 32 bytes string-wise.
[[ -z "$COOKIE_SECRET" || ${#COOKIE_SECRET} -ne 32 ]] && COOKIE_SECRET=$(openssl rand -hex 16)
sed -e "s|__DEX_CLIENT_SECRET__|$DEX_CLIENT_SECRET|" \
    -e "s|__COOKIE_SECRET__|$COOKIE_SECRET|" \
    "$REPO_ROOT/manifests/oauth2-proxy/values.template.yaml" > /tmp/oauth2-proxy-values.yaml
helm_upgrade_install oauth2-proxy oauth2-proxy/oauth2-proxy \
  --version 10.4.3 \
  -n "$NS_PLATFORM" \
  -f /tmp/oauth2-proxy-values.yaml
kubectl -n "$NS_PLATFORM" rollout status deploy/oauth2-proxy --timeout=120s | tail -1
rm -f /tmp/oauth2-proxy-values.yaml

# Hack: the oauth2-proxy chart's extraArgs map munges 'auto' to empty.
# Patch the deployment directly so approval-prompt=auto, which lets dex's
# skipApprovalScreen kick in (otherwise users get a "Grant Access" page).
kubectl -n "$NS_PLATFORM" get deploy oauth2-proxy -o json | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
args = d['spec']['template']['spec']['containers'][0]['args']
args = ['--approval-prompt=auto' if a == '--approval-prompt=' else a for a in args]
d['spec']['template']['spec']['containers'][0]['args'] = args
print(json.dumps(d))" | kubectl apply -f - >/dev/null
kubectl -n "$NS_PLATFORM" rollout status deploy/oauth2-proxy --timeout=60s | tail -1

log_step "6.6 — Anthropic API key Secret"
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY not set"
kubectl -n "$NS_BANK_AGENTS" create secret generic kagent-anthropic \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

log_step "6.7 — ModelConfig"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/modelconfig.yaml"

log_step "6.8 — RemoteMCPServer (point at agentgateway, NOT MCP servers directly)"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/remote-mcp-servers.yaml"

log_step "6.9-6.11 — Agent CRDs"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/agent-support-bot.yaml"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/agent-fraud-bot.yaml"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/agent-triage-bot.yaml"

log_step "6.12 — verifying agents"
kubectl -n "$NS_BANK_AGENTS" wait --for=condition=Ready agents.kagent.dev --all --timeout=300s || \
  log_warn "agents not all Ready — check kubectl describe agents -n $NS_BANK_AGENTS"

log_step "6.13 — agent telemetry → OTel"
kubectl_apply "$MANIFESTS_DIR/phase06-kagent/telemetry.yaml"

log_step "6.14 — evidence (DORA Art. 17)"
P6=$(evidence_dir 6)
kubectl -n "$NS_BANK_AGENTS" get agents.kagent.dev -o yaml > "$P6/agents.yaml" || true

log_ok "Phase 6 (kagent Enterprise + dex + oauth2-proxy) complete"
log ""
log "Login URL: http://localhost:18007/  (after running scripts/port-forward.sh)"
log "Credentials: admin@kagent.local / admin"
