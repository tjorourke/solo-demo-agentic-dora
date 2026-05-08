#!/usr/bin/env bash
# Reverse a deploy. Stops port-forwards, helm uninstalls in reverse order,
# deletes namespaces. With --full, also deletes the kind cluster.
# Usage:
#   ./teardown.sh                # remove releases + namespaces, keep cluster
#   ./teardown.sh --full         # also delete the cluster
#   ./teardown.sh --eks          # treat as EKS (does NOT delete EKS cluster automatically)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

trap on_error ERR

FULL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL=1; shift ;;
    --eks)  export CLUSTER_KIND=eks; shift ;;
    --kind) export CLUSTER_KIND=kind; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

log_step "Stopping port-forwards"
stop_all_port_forwards || true

log_step "Helm uninstalls (reverse order)"
RELEASES=(
  "kagent:$NS_PLATFORM"
  "kagent-crds:$NS_PLATFORM"
  "agentgateway:$NS_PLATFORM"
  "agentgateway-crds:$NS_PLATFORM"
  "keycloak:$NS_PLATFORM"
  "agentregistry:$NS_PLATFORM"
  "otel-collector:$NS_OBS"
  "loki:$NS_OBS"
  "tempo:$NS_OBS"
  "kube-prometheus-stack:$NS_OBS"
)
for r in "${RELEASES[@]}"; do
  IFS=":" read -r name ns <<< "$r"
  if helm -n "$ns" status "$name" >/dev/null 2>&1; then
    helm -n "$ns" uninstall "$name" || log_warn "uninstall $name failed (continuing)"
  fi
done

log_step "istioctl uninstall (Ambient)"
if command -v istioctl >/dev/null 2>&1 && kubectl get ns istio-system >/dev/null 2>&1; then
  istioctl uninstall --purge -y || log_warn "istioctl uninstall failed (continuing)"
fi

log_step "Deleting namespaces"
for ns in "${ALL_NAMESPACES[@]}"; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    kubectl delete ns "$ns" --wait=false || true
  fi
done

if (( FULL == 1 )); then
  if [[ "$CLUSTER_KIND" == "kind" ]]; then
    log_step "Deleting kind cluster $CLUSTER_NAME"
    kind delete cluster --name "$CLUSTER_NAME" || true
  else
    log_warn "EKS teardown is manual — run: eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION"
  fi
fi

log_ok "teardown complete"
