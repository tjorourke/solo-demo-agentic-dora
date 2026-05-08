#!/usr/bin/env bash
# Phase 5 — agentgateway: install + Keycloak + Gateway/Backends/HTTPRoutes/Policies.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

helm_repo_add_once bitnami https://charts.bitnami.com/bitnami

log_step "5.1 — agentgateway CRDs (OCI chart from cr.agentgateway.dev)"
helm_upgrade_install agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds \
  -n "$NS_PLATFORM" --version "$AGENTGATEWAY_VERSION"

log_step "5.2 — agentgateway control plane (OCI chart)"
helm_upgrade_install agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  -n "$NS_PLATFORM" --version "$AGENTGATEWAY_VERSION"

wait_for_pods_ready "$NS_PLATFORM" "app.kubernetes.io/name=agentgateway" 300s

log_step "5.3 — Gateway resource"
kubectl_apply "$MANIFESTS_DIR/phase05-agentgateway/gateway.yaml"

log_step "5.4 — AgentgatewayBackends (4 backends)"
kubectl_apply "$MANIFESTS_DIR/phase05-agentgateway/backends.yaml"

log_step "5.5 — HTTPRoutes"
kubectl_apply "$MANIFESTS_DIR/phase05-agentgateway/httproutes.yaml"

log_step "5.6 — Keycloak install (official quay.io image, no Bitnami)"
kubectl_apply "$MANIFESTS_DIR/phase05-agentgateway/keycloak.yaml"
wait_for_ready deployment keycloak "$NS_PLATFORM" 300s

log_step "5.7 — Keycloak realm import"
# Apply realm import job (idempotent — kc.sh will reconcile)
kubectl_apply "$MANIFESTS_DIR/phase05-agentgateway/keycloak-realm-import.yaml"

log_step "5.8 — JWT validation policy"
kubectl_apply "$MANIFESTS_DIR/phase05-agentgateway/jwt-policy.yaml"

log_step "5.9 — tool allowlist policies"
kubectl_apply "$MANIFESTS_DIR/phase05-agentgateway/tool-allowlist.yaml"

log_step "5.10 — rate limit policy"
kubectl_apply "$MANIFESTS_DIR/phase05-agentgateway/rate-limit.yaml"

log_step "5.11 — prompt-guard policy"
kubectl_apply "$MANIFESTS_DIR/phase05-agentgateway/prompt-guard.yaml"

log_step "5.12 — evidence (DORA Art. 9 + 10)"
P5=$(evidence_dir 5)
kubectl -n "$NS_PLATFORM" logs deploy/agentgateway --tail=200 > "$P5/access-log-bootstrap.jsonl" || true

log_ok "Phase 5 (agentgateway) complete"
