#!/usr/bin/env bash
# Phase 0.3-0.7 — create cluster, install Gateway API CRDs, create namespaces.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

if [[ "$CLUSTER_KIND" == "kind" ]]; then
  log_step "0.3 — kind cluster '$CLUSTER_NAME'"
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log_ok "kind cluster $CLUSTER_NAME already exists"
  else
    kind create cluster --name "$CLUSTER_NAME" --config "$REPO_ROOT/kind-config.yaml"
  fi
  kubectl config use-context "kind-${CLUSTER_NAME}"

  # Local registry container for kind (so we don't need a remote registry)
  log_step "0.3a — local container registry"
  if ! docker inspect kind-registry >/dev/null 2>&1; then
    docker run -d --restart=always -p 127.0.0.1:5001:5000 --network bridge --name kind-registry registry:2
  fi
  if ! docker network inspect kind | grep -q kind-registry; then
    docker network connect kind kind-registry || true
  fi
  # Tell kind nodes about the registry
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:5001"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
elif [[ "$CLUSTER_KIND" == "eks" ]]; then
  log_step "0.4 — EKS cluster '$CLUSTER_NAME' in $AWS_REGION"
  if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    log_ok "EKS cluster $CLUSTER_NAME already exists"
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
  else
    eksctl create cluster -f "$REPO_ROOT/eks-config.yaml"
  fi
else
  die "unknown CLUSTER_KIND: $CLUSTER_KIND"
fi

kubectl get nodes

log_step "0.5 — Gateway API CRDs (standard channel) $GATEWAY_API_VERSION"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log_step "0.6 — Gateway API CRDs (experimental channel)"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

log_step "0.7 — namespaces"
ensure_namespace "$NS_PLATFORM"
ensure_namespace "$NS_OBS"
for ns in "${AMBIENT_NAMESPACES[@]}"; do
  ensure_namespace "$ns" "istio.io/dataplane-mode=ambient"
done

log "Ambient-labelled namespaces:"
kubectl get ns -l istio.io/dataplane-mode=ambient

log_ok "Phase 0 (cluster + Gateway API + namespaces) complete"
