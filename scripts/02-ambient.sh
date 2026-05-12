#!/usr/bin/env bash
# Phase 1 — Istio Ambient mesh: ztunnel, waypoints, AuthorizationPolicies.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

require_cmd istioctl

log_step "1.1 — istioctl install (profile=ambient)"
# Idempotent — istioctl install will reconcile to the requested state
istioctl install --set profile=ambient -y

log_step "1.2 — verify ztunnel DaemonSet"
kubectl -n istio-system rollout status ds/ztunnel --timeout=180s

log_step "1.3 — waypoint in $NS_BANK_MCP"
istioctl waypoint apply -n "$NS_BANK_MCP" --enroll-namespace --wait

log_step "1.4 — waypoint in $NS_BANK_AGENTS"
istioctl waypoint apply -n "$NS_BANK_AGENTS" --enroll-namespace --wait

log_step "1.5 — default deny AuthorizationPolicy"
kubectl_apply "$MANIFESTS_DIR/phase01-ambient/deny-all-cross-ns.yaml"

log_step "1.6 — allow agents → mcp"
kubectl_apply "$MANIFESTS_DIR/phase01-ambient/allow-agents-to-mcp.yaml"

log_step "1.7 — HBONE check (best effort)"
SNIFFER_NS="$NS_BANK_AGENTS"
if ! kubectl -n "$SNIFFER_NS" get pod hbone-sniffer >/dev/null 2>&1; then
  kubectl -n "$SNIFFER_NS" run hbone-sniffer --image=nicolaka/netshoot --restart=Never --command -- sleep 3600 || true
fi
log "deploy a sniffer pod and tcpdump for port 15008 to verify HBONE — see plan §1.7"

log_step "1.6a — bump ztunnel log level so AuthZ denials are visible"
# Default ztunnel RUST_LOG=info logs only successful connections.
# AuthZ denies are suppressed at debug level. In production you'd want
# `access=debug` so denies surface as 'error  access  connection complete'
# lines — that's what Promtail picks up for Loki + the DORA Evidence
# dashboard. This is an UPSTREAM Istio Ambient default, not a Solo issue.
kubectl -n istio-system set env ds/ztunnel \
  RUST_LOG="info,access=debug,proxy::access_log=debug" 2>&1 | sed 's/^/    /' || true
kubectl -n istio-system rollout status ds/ztunnel --timeout=120s 2>&1 | tail -1 | sed 's/^/    /' || true

log_step "1.7a — deploy mock-attacker (the demo's C2 server stand-in)"
# This pod lives outside every trustusbank-* namespace. It's the
# exfiltration target the malicious tool tries to reach. Solo's
# policies-on.sh later applies a deny rule that blocks bank-* → here.
MA_IMG="${IMAGE_PREFIX}/mock-attacker:1.0.0"
if ! docker image inspect "$MA_IMG" >/dev/null 2>&1; then
  docker build -t "$MA_IMG" "$REPO_ROOT/services/mock-attacker" 2>&1 | tail -2
fi
docker push "$MA_IMG" 2>&1 | tail -1 || \
  kind load docker-image "$MA_IMG" --name "$CLUSTER_NAME"
kubectl_apply "$MANIFESTS_DIR/phase01-attacker/mock-attacker.yaml"
wait_for_ready deployment mock-attacker external-attacker 60s 2>/dev/null || true

log_step "1.8 — evidence capture (DORA Art. 9(2))"
P1=$(evidence_dir 1)
kubectl -n istio-system logs ds/ztunnel --tail=200 > "$P1/ztunnel-startup.log" || true
kubectl get authorizationpolicy -A -o yaml > "$P1/authorization-policies.yaml" || true
log_ok "evidence saved to $P1"

log_ok "Phase 1 (Ambient) complete"
