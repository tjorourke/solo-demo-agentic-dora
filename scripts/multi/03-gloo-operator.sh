#!/usr/bin/env bash
# Phase M03 — Solo Gloo Operator install.
#
# Replaces the previous "4 helm releases per cluster" pattern (base /
# istiod / istio-cni / ztunnel) with a single declarative CR per cluster.
#
# Production-best-practice flow (matches Solo's documented pattern):
#   1. IT installs the Gloo Operator chart once per cluster (gloo-system ns).
#      Operator watches operator.gloo.solo.io CRDs cluster-scoped.
#   2. IT creates a one-time `solo-istio-license` Secret in istio-system
#      holding the Solo Istio license key. The operator-installed istiod
#      reads this Secret when applying the licensed Solo distribution.
#   3. IT creates a docker-pull Secret if pulling from a private registry
#      (the SMC's spec.image.secrets references it).
#   4. Per cluster, IT applies a ServiceMeshController CR declaring:
#        cluster, network, trustDomain  (the multi-cluster identity tuple)
#        version                         (Istio version, e.g. 1.29.2-patch0-solo)
#        dataplaneMode: Ambient         (default for new installs)
#        distribution: Standard         (Solo Istio standard; FIPS available)
#        scalingProfile: Demo           (kind-friendly resource ask)
#        image:                          (private Solo registry override)
#          registry, repository, secrets
#   5. App teams never touch istio-system. The operator reconciles the
#      mesh; humans only see `kubectl get servicemeshcontroller -A`.
#
# The operator handles base + istiod + cni + ztunnel as a single
# lifecycle. Upgrades become editing the .spec.version field.
#
# East/west peering for multi-cluster is still applied via the peering
# helm chart (scripts/multi/04-peering.sh) — at the time of writing the
# operator does not yet manage peering CRs. That stays as a separate
# concern.
#
# Image pull strategy on kind: we pre-pull the Solo Istio images on the
# host (which has gcloud creds) and `kind load` them into each cluster.
# That bypasses the need for an in-cluster pull Secret.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "03-gloo-operator.sh requires MODE=multi"
[[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]] || die "SOLO_ISTIO_LICENSE_KEY not set"

OPERATOR_VERSION="${GLOO_OPERATOR_VERSION:-0.5.2}"
OPERATOR_CHART="oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator"
ISTIO_VERSION_PLAIN="${SOLO_ISTIO_VERSION:-1.29.2-patch0-solo}"
# Strip the trailing "-solo" suffix. The operator auto-appends "-solo"
# when distribution=Standard (because it fetches Solo Istio's licensed
# charts at oci://.../<chart>:<version>-solo). Passing "1.29.2-patch0-solo"
# as-is produces a 404 on "<chart>:1.29.2-patch0-solo-solo".
ISTIO_VERSION="${ISTIO_VERSION_PLAIN%-solo}"
ISTIO_REGISTRY="us-docker.pkg.dev/soloio-img/istio"

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
  "$ISTIO_REGISTRY/pilot:$ISTIO_VERSION"
  "$ISTIO_REGISTRY/proxyv2:$ISTIO_VERSION"
  "$ISTIO_REGISTRY/install-cni:$ISTIO_VERSION"
  "$ISTIO_REGISTRY/ztunnel:$ISTIO_VERSION"
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

# Gateway API experimental CRDs — required for ambient (waypoints, peering chart).
log_step "installing Gateway API experimental CRDs ($GATEWAY_API_VERSION)"
GW_API_YAML="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
for cluster in "${CLUSTERS[@]}"; do
  log "  $cluster"
  kctx "$cluster" apply --server-side --force-conflicts -f "$GW_API_YAML" >/dev/null
done

# ---------- Install gloo-operator on each cluster ----------
log_step "installing gloo-operator $OPERATOR_VERSION on each cluster"
for cluster in "${CLUSTERS[@]}"; do
  ctx="$(cluster_context "$cluster")"
  log "  [$cluster] helm install gloo-operator"
  kubectl --context="$ctx" create ns gloo-system --dry-run=client -o yaml | \
    kubectl --context="$ctx" apply -f - >/dev/null
  helm --kube-context="$ctx" upgrade --install gloo-operator "$OPERATOR_CHART" \
    --version "$OPERATOR_VERSION" \
    -n gloo-system \
    --wait --timeout 3m >/dev/null
done

# ---------- Solo Istio license + namespace prep ----------
log_step "creating istio-system namespace + license Secret on each cluster"
for cluster in "${CLUSTERS[@]}"; do
  ctx="$(cluster_context "$cluster")"
  kubectl --context="$ctx" create ns istio-system --dry-run=client -o yaml | \
    kubectl --context="$ctx" apply -f - >/dev/null
  # The Solo Istio chart that the operator installs reads the license key
  # from a Secret named `solo-istio-license` in istio-system (key=license).
  # Same name regardless of cluster — the operator passes it through to
  # the licensed istiod chart.
  kubectl --context="$ctx" -n istio-system create secret generic solo-istio-license \
    --from-literal=license="$SOLO_ISTIO_LICENSE_KEY" \
    --dry-run=client -o yaml | kubectl --context="$ctx" apply -f - >/dev/null
  log_ok "  [$cluster] license Secret applied"
done

# ---------- Apply ServiceMeshController CR per cluster ----------
log_step "applying ServiceMeshController per cluster"
for cluster in "${CLUSTERS[@]}"; do
  ctx="$(cluster_context "$cluster")"
  td="$(trust_domain_for "$cluster")"
  log "  [$cluster] kubectl apply ServiceMeshController (cluster=$cluster, network=$cluster, trustDomain=$td)"

  kubectl --context="$ctx" apply -f - <<EOF >/dev/null
apiVersion: operator.gloo.solo.io/v1
kind: ServiceMeshController
metadata:
  name: managed-istio
  labels:
    app.kubernetes.io/part-of: trustusbank
spec:
  # Identity tuple — set distinctly per cluster for multi-cluster identity.
  cluster: $cluster
  network: $cluster
  trustDomain: $td

  # Mesh shape.
  version: "$ISTIO_VERSION"
  dataplaneMode: Ambient
  distribution: Standard
  installNamespace: istio-system
  scalingProfile: Demo
  trafficCaptureMode: Auto

  # If the existing istio-system has already-installed resources from a
  # previous (helm-based) install, "Force" tells the operator to update
  # in place rather than abort. Use "Abort" in greenfield production.
  onConflict: Force

  # Image registry (Solo Istio standard distribution). On kind we pre-load
  # via 'kind load' so no in-cluster pull Secret is required.
  image:
    registry: us-docker.pkg.dev
    repository: soloio-img/istio
EOF
done

# ---------- Wait for reconcile ----------
log_step "waiting for ServiceMeshController status to settle on each cluster"
# The operator's terminal "good" status is .status.phase = SUCCEEDED (also
# accept INSTALLED for older operator versions). FAILED / ABORTED are the
# error terminal states; PENDING is in-progress.
for cluster in "${CLUSTERS[@]}"; do
  ctx="$(cluster_context "$cluster")"
  log "  [$cluster] waiting for .status.phase = SUCCEEDED"
  for i in $(seq 1 60); do
    phase=$(kubectl --context="$ctx" get servicemeshcontroller managed-istio \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    case "$phase" in
      SUCCEEDED|INSTALLED|Installed)
        log_ok "  [$cluster] $phase"
        break
        ;;
      FAILED|ABORTED|Failed|Aborted)
        log_warn "  [$cluster] phase=$phase — inspecting status"
        kubectl --context="$ctx" get servicemeshcontroller managed-istio \
          -o jsonpath='{.status.conditions}' 2>&1 | sed 's/^/      /'
        die "ServiceMeshController failed on $cluster"
        ;;
    esac
    sleep 5
  done
done

# ---------- Verify the four mesh components are up ----------
log_step "verifying mesh data plane on each cluster"
for cluster in "${CLUSTERS[@]}"; do
  ctx="$(cluster_context "$cluster")"
  log "  [$cluster]:"
  kubectl --context="$ctx" -n istio-system get pods -o wide --no-headers 2>&1 \
    | awk '{printf "    %-40s %s %s\n", $1, $2, $3}'
done

log_ok "Phase M03 (Gloo Operator + ServiceMeshController on 3 clusters) complete"
log "  next: M04 east/west peering — peering charts stay separate until the"
log "        operator's peering CR support matures"
log ""
log "Inspect the operator-managed mesh:"
log "  kubectl get servicemeshcontroller -A  # one Installed per cluster"
log "  kubectl describe servicemeshcontroller managed-istio"
