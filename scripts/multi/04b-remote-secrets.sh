#!/usr/bin/env bash
# Phase M04b — istio-remote-secret-* (the control-plane half of peering).
#
# The peering helm chart (04-peering.sh) only sets up the DATA plane:
# east-west GW + remote-peer Gateway CRs that point at peer node IPs.
# For multi-cluster *control-plane* discovery — where each cluster's
# istiod-gloo reads Services/Endpoints/Pods from the other clusters'
# Kubernetes APIs — we also need an `istio-remote-secret-<cluster>` Secret
# in every consumer cluster's istio-system, containing a kubeconfig that
# points at the producer cluster's API with a long-lived token bound to
# the istio-reader-service-account.
#
# Without these, istiod-gloo's "Number of remote clusters: 0" — no remote
# services land in its registry, no endpoint shards exist, and the
# *.mesh.internal / *.svc.cluster.local cross-cluster hostnames resolve to
# VIPs with zero endpoints (TCP reset).
#
# This is the equivalent of `istioctl x create-remote-secret` from upstream
# Istio, but rendered as a deterministic YAML so we don't need Solo's
# istioctl in PATH (which would require a separate download).

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "04b-remote-secrets.sh requires MODE=multi"

# Map cluster → routable API address on the shared kind docker network.
# (`docker inspect <ctrl-plane> --format ...` exposes it; we read at apply
# time because kind/docker can re-assign IPs across restarts.)
node_ip_of() {
  docker inspect "${1}-control-plane" \
    --format '{{ .NetworkSettings.Networks.kind.IPAddress }}'
}

# Build the per-cluster remote-secret YAML. Same shape as upstream Istio's
# `istioctl x create-remote-secret`. Token is bound to the
# `istio-reader-service-account` which Solo Istio creates by default and
# already has the right cluster-wide read RBAC.
render_remote_secret() {
  local target="$1"   # cluster the secret describes (kubeconfig points HERE)
  local node_ip="$2"
  local ca_b64
  local token
  ca_b64=$(kctx "$target" -n istio-system get cm kube-root-ca.crt \
    -o jsonpath='{.data.ca\.crt}' | base64 | tr -d '\n')
  # 87600h = 10 years. Long-lived but bound to the SA — rotate by re-running.
  token=$(kctx "$target" -n istio-system create token istio-reader-service-account \
    --duration 87600h)
  cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: istio-remote-secret-$target
  namespace: istio-system
  labels:
    istio/multiCluster: "true"
  annotations:
    networking.istio.io/cluster: $target
type: Opaque
stringData:
  $target: |
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        certificate-authority-data: $ca_b64
        server: https://$node_ip:6443
      name: $target
    contexts:
    - context:
        cluster: $target
        user: $target
      name: $target
    current-context: $target
    users:
    - name: $target
      user:
        token: $token
EOF
}

log_step "creating istio-remote-secret-* (cross-cluster k8s API kubeconfigs)"

# Generate one secret per cluster, then apply it to every OTHER cluster.
declare -A SECRET_YAML
for target in "${CLUSTERS[@]}"; do
  ip="$(node_ip_of "$target")"
  log "  rendering remote-secret for $target (api: $ip:6443)"
  SECRET_YAML[$target]="$(render_remote_secret "$target" "$ip")"
done

for consumer in "${CLUSTERS[@]}"; do
  for producer in "${CLUSTERS[@]}"; do
    [[ "$producer" == "$consumer" ]] && continue
    log "  applying remote-secret-$producer to $consumer"
    echo "${SECRET_YAML[$producer]}" | kctx "$consumer" apply -f - >/dev/null
  done
done

# Force-restart istiod-gloo so the new secrets get picked up by the
# multicluster-secret controller during its next init sweep. (It also
# watches at runtime, but restarting eliminates any state-cache surprises.)
log_step "restarting istiod-gloo to pick up remote-secrets"
for cluster in "${CLUSTERS[@]}"; do
  kctx "$cluster" -n istio-system rollout restart deploy istiod-gloo >/dev/null
done
for cluster in "${CLUSTERS[@]}"; do
  kctx "$cluster" -n istio-system rollout status deploy istiod-gloo --timeout=2m >/dev/null
done

# Sanity: each istiod should report "Number of remote clusters: 2".
log_step "verifying istiod-gloo sees both peer clusters"
sleep 10
for cluster in "${CLUSTERS[@]}"; do
  n=$(kctx "$cluster" -n istio-system logs deploy/istiod-gloo --tail=200 2>/dev/null \
    | grep -E "Number of remote clusters: [0-9]+" | tail -1 | awk '{print $NF}')
  if [[ "$n" == "2" ]]; then
    log_ok "  [$cluster] sees 2 remote clusters"
  else
    log_warn "  [$cluster] saw '$n' remote clusters — expected 2"
  fi
done

log_ok "Phase M04b (istio-remote-secret-*) complete"
log "  next: M05 namespaces — workload nss get topology.istio.io/network labels"
log "        so istiod can rewrite cross-cluster endpoints to the east-west GW"
