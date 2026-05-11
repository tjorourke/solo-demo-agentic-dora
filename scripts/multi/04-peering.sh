#!/usr/bin/env bash
# Phase M04 — east/west peering across the three clusters.
#
# Two helm installs per cluster, using oci://.../istio-helm/peering:
#   1. local east/west gateway       (eastwest.create=true)
#   2. remote peer references         (remote.create=true with the other 2
#                                      clusters in remote.items[])
#
# Kind has no LoadBalancers, so we pin the east/west Service to NodePort with
# fixed ports (15008 hbone, 15012 xds, advertised via nodePort 30015/30016).
# Same ports across all 3 clusters — they're cluster-local NodePorts; the
# control-plane node IP differs (and is what `remote.items[].address` uses).

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "04-peering.sh requires MODE=multi"

VER="${SOLO_ISTIO_VERSION:-1.29.2-patch0-solo}"
HELM_REPO=us-docker.pkg.dev/soloio-img/istio-helm

# Fixed NodePorts so remote peers can be configured deterministically.
EW_HBONE_NODEPORT=30015
EW_XDS_NODEPORT=30016

trust_domain_for() {
  case "$1" in
    "$EDGE_CLUSTER")   echo edge.local   ;;
    "$BANK_CLUSTER")   echo bank.local   ;;
    "$VENDOR_CLUSTER") echo vendor.local ;;
  esac
}

# istiod's peering controller refuses to publish remote endpoints unless
# istio-system is labelled with the cluster's network. The helm chart does
# not apply this label automatically. Missing label → endless retries
# "fetched namespace istio-system but 'topology.istio.io/network' is not set".
log_step "labelling istio-system with topology.istio.io/network per cluster"
for cluster in "${CLUSTERS[@]}"; do
  kctx "$cluster" label ns istio-system "topology.istio.io/network=${cluster}" --overwrite >/dev/null
done

# ---------- Step 1: local east/west gateway in each cluster ----------

for cluster in "${CLUSTERS[@]}"; do
  log_step "[$cluster] installing east/west gateway"

  # Ensure the namespace exists with ambient mode (the GW pods run in the mesh).
  kctx "$cluster" create namespace istio-eastwest --dry-run=client -o yaml \
    | kctx "$cluster" apply -f - >/dev/null

  cat > /tmp/peering-ew-$cluster.yaml <<EOF
eastwest:
  create: true
  cluster: $cluster
  network: $cluster
  dataplaneServiceTypes:
    - nodeport
  service:
    spec:
      type: NodePort
      ports:
        - name: tls-hbone
          port: 15008
          nodePort: $EW_HBONE_NODEPORT
          protocol: TCP
        - name: tls-xds
          port: 15012
          nodePort: $EW_XDS_NODEPORT
          protocol: TCP
remote:
  create: false
EOF

  helm --kube-context="$(cluster_context "$cluster")" upgrade --install \
    peering-eastwest "oci://$HELM_REPO/peering" \
    --namespace istio-eastwest \
    --version "$VER" \
    -f /tmp/peering-ew-$cluster.yaml \
    --wait --timeout 5m >/dev/null

  log_ok "[$cluster] east/west GW installed"
done

# Discover each cluster's control-plane node IP on the shared kind docker network.
declare_node_ip() {
  docker inspect "${1}-control-plane" --format '{{ .NetworkSettings.Networks.kind.IPAddress }}'
}

EDGE_IP="$(declare_node_ip "$EDGE_CLUSTER")"
BANK_IP="$(declare_node_ip "$BANK_CLUSTER")"
VENDOR_IP="$(declare_node_ip "$VENDOR_CLUSTER")"

log_step "east/west GW endpoints"
log "  edge   $EDGE_IP:$EW_HBONE_NODEPORT (hbone) :$EW_XDS_NODEPORT (xds)"
log "  bank   $BANK_IP:$EW_HBONE_NODEPORT (hbone) :$EW_XDS_NODEPORT (xds)"
log "  vendor $VENDOR_IP:$EW_HBONE_NODEPORT (hbone) :$EW_XDS_NODEPORT (xds)"

# ---------- Step 2: remote peer references ----------
# Each cluster gets a `remote` install listing the *other two* clusters as
# peers. The chart provisions ServiceEntry + DestinationRule + WorkloadEntry
# resources so istiod can route SNI-multiplexed HBONE traffic out through
# the local east/west GW to the remote.

write_remote_values() {
  local cluster="$1"; local file="$2"
  cat > "$file" <<EOF
eastwest:
  create: false
remote:
  create: true
  items:
EOF
  for peer in "${CLUSTERS[@]}"; do
    [[ "$peer" == "$cluster" ]] && continue
    local peer_ip peer_td
    peer_ip="$(declare_node_ip "$peer")"
    peer_td="$(trust_domain_for "$peer")"
    cat >> "$file" <<EOF
    - name: peer-$peer
      cluster: $peer
      network: $peer
      address: $peer_ip
      addressType: IPAddress
      trustDomain: $peer_td
      preferredDataplaneServiceType: nodeport
      nodeport: $EW_XDS_NODEPORT
EOF
  done
}

for cluster in "${CLUSTERS[@]}"; do
  log_step "[$cluster] installing remote peer references"
  write_remote_values "$cluster" /tmp/peering-remote-$cluster.yaml
  helm --kube-context="$(cluster_context "$cluster")" upgrade --install \
    peering-remote "oci://$HELM_REPO/peering" \
    --namespace istio-eastwest \
    --version "$VER" \
    -f /tmp/peering-remote-$cluster.yaml \
    --wait --timeout 5m >/dev/null
  log_ok "[$cluster] remote peers wired"
done

# ---------- Verification ----------

log_step "east/west GW pods"
for cluster in "${CLUSTERS[@]}"; do
  log "  $cluster:"
  kctx "$cluster" -n istio-eastwest get pods --no-headers \
    | awk '{printf "    %-45s %s %s\n", $1, $2, $3}'
done

log_step "east/west GW Services (NodePort allocations)"
for cluster in "${CLUSTERS[@]}"; do
  log "  $cluster:"
  kctx "$cluster" -n istio-eastwest get svc --no-headers \
    | awk '{printf "    %-30s %-12s %s\n", $1, $2, $5}'
done

log_ok "Phase M04 (east/west peering) complete"
log "  next: M05 namespaces + ambient labels per placement table"
