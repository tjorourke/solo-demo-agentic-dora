#!/usr/bin/env bash
# Phase M03 — install Solo Enterprise for Istio (Ambient flavor) on each
# of the three kind clusters.
#
# Charts come from oci://us-docker.pkg.dev/soloio-img/istio-helm/* at the
# version pinned in .env (SOLO_ISTIO_VERSION, default 1.29.2-patch0-solo).
# Each cluster gets its own clusterName + network + trustDomain (the three
# values that distinguish a cluster in Istio's multi-cluster identity
# model). license.value is passed to istiod from SOLO_ISTIO_LICENSE_KEY.
#
# Image pull strategy: pre-pull on the host (which has gcloud creds for
# us-docker.pkg.dev), then `kind load` each image into each cluster's
# containerd. Kind nodes don't have gcloud creds themselves and the chart
# default imagePullSecrets pattern would need an extra secret hop; this is
# simpler for kind.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "03-solo-istio.sh requires MODE=multi"
[[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]] || die "SOLO_ISTIO_LICENSE_KEY not set"

VER="${SOLO_ISTIO_VERSION:-1.29.2-patch0-solo}"
REPO=us-docker.pkg.dev/soloio-img/istio
HELM_REPO=us-docker.pkg.dev/soloio-img/istio-helm

# Trust domain per cluster (matches what M02 baked into the intermediates).
trust_domain_for() {
  case "$1" in
    "$EDGE_CLUSTER")   echo edge.local   ;;
    "$BANK_CLUSTER")   echo bank.local   ;;
    "$VENDOR_CLUSTER") echo vendor.local ;;
  esac
}

# Images that need to land on each cluster's containerd.
IMAGES=(
  "$REPO/pilot:$VER"
  "$REPO/proxyv2:$VER"
  "$REPO/install-cni:$VER"
  "$REPO/ztunnel:$VER"
)

log_step "pre-pulling Solo Istio images on host"
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    log_ok "  already cached: $img"
  else
    log "  pulling $img"
    docker pull --quiet "$img"
  fi
done

log_step "loading images into each kind cluster"
for cluster in "${CLUSTERS[@]}"; do
  for img in "${IMAGES[@]}"; do
    log "  $cluster ← $(basename "$img")"
    kind load docker-image "$img" --name "$cluster" 2>&1 \
      | grep -E "Image:|Error" | sed 's/^/    /' || true
  done
done

# Helm install order matters:
#   base       — CRDs and global resources
#   istiod     — control plane (needs cacerts from M02)
#   istio-cni  — required for Ambient
#   ztunnel    — Ambient L4 data plane (per node)

for cluster in "${CLUSTERS[@]}"; do
  td="$(trust_domain_for "$cluster")"
  log_step "[$cluster] installing Solo Istio Ambient ($VER, trustDomain=$td)"

  log "  helm: istio-base"
  helm --kube-context="$(cluster_context "$cluster")" upgrade --install \
    istio-base "oci://$HELM_REPO/base" \
    --namespace istio-system --create-namespace \
    --version "$VER" \
    --set defaultRevision="" \
    --set profile=ambient \
    --wait --timeout 5m >/dev/null

  log "  helm: istiod"
  # NOTE on chart keys:
  #   global.trustDomain — does NOT exist in this chart (cluster.local default
  #     is kept and the helm value is silently dropped). Use meshConfig.trustDomain
  #     which is the real path through the mesh ConfigMap that istiod reads.
  helm --kube-context="$(cluster_context "$cluster")" upgrade --install \
    istiod "oci://$HELM_REPO/istiod" \
    --namespace istio-system \
    --version "$VER" \
    --set profile=ambient \
    --set env.PILOT_ENABLE_IP_AUTOALLOCATE=true \
    --set env.DISABLE_LEGACY_MULTICLUSTER=true \
    --set env.PILOT_SKIP_VALIDATE_TRUST_DOMAIN=true \
    --set global.multiCluster.clusterName="$cluster" \
    --set global.network="$cluster" \
    --set meshConfig.trustDomain="$td" \
    --set platforms.peering.enabled=true \
    --set license.value="$SOLO_ISTIO_LICENSE_KEY" \
    --wait --timeout 5m >/dev/null

  log "  helm: istio-cni"
  helm --kube-context="$(cluster_context "$cluster")" upgrade --install \
    istio-cni "oci://$HELM_REPO/cni" \
    --namespace istio-system \
    --version "$VER" \
    --set profile=ambient \
    --set ambient.dnsCapture=true \
    --wait --timeout 5m >/dev/null

  log "  helm: ztunnel"
  helm --kube-context="$(cluster_context "$cluster")" upgrade --install \
    ztunnel "oci://$HELM_REPO/ztunnel" \
    --namespace istio-system \
    --version "$VER" \
    --set profile=ambient \
    --set multiCluster.clusterName="$cluster" \
    --set network="$cluster" \
    --wait --timeout 5m >/dev/null

  log_ok "[$cluster] Solo Istio Ambient installed"
done

# Verify the control plane on each cluster is up.
log_step "verifying control planes"
for cluster in "${CLUSTERS[@]}"; do
  log "  $cluster:"
  kctx "$cluster" -n istio-system get pods -o wide --no-headers \
    | awk '{printf "    %-40s %s %s\n", $1, $2, $3}'
done

log_ok "Phase M03 (Solo Istio Ambient on 3 clusters) complete"
log "  next: M04 east/west peering to wire the three control planes together"
