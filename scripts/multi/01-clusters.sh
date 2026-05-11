#!/usr/bin/env bash
# Phase M01 — create the three kind clusters for the multi-cluster variant
# and wire them to a shared local docker registry.
#
# kind by default puts every cluster on the same "kind" docker network, so
# the three clusters can reach each other's NodePorts by node IP. We use
# non-overlapping pod/service CIDRs in kind/multi-*.yaml so pod-to-pod via
# east/west GW NodePorts works deterministically once the peering chart is
# installed.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "01-clusters.sh requires MODE=multi"

create_cluster() {
  local cluster="$1" config="$2"
  if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
    log_ok "kind cluster $cluster already exists"
  else
    log_step "creating kind cluster $cluster"
    kind create cluster --name "$cluster" --config "$config"
  fi
}

create_cluster "$EDGE_CLUSTER"   "$REPO_ROOT/kind/multi-edge.yaml"
create_cluster "$BANK_CLUSTER"   "$REPO_ROOT/kind/multi-bank.yaml"
create_cluster "$VENDOR_CLUSTER" "$REPO_ROOT/kind/multi-vendor.yaml"

log_step "shared local registry (kind-registry)"
# Same pattern as the single-cluster phase01 — one registry container on the
# shared kind network, mirrored at localhost:5001 from each node's containerd.
if ! docker inspect kind-registry >/dev/null 2>&1; then
  docker run -d --restart=always -p 127.0.0.1:5001:5000 --network bridge --name kind-registry registry:2
fi
if ! docker network inspect kind | grep -q kind-registry; then
  docker network connect kind kind-registry || true
fi

REG_DIR="/etc/containerd/certs.d/localhost:5001"
for cluster in "${CLUSTERS[@]}"; do
  for node in $(kind get nodes --name "$cluster"); do
    docker exec "$node" mkdir -p "$REG_DIR"
    docker exec -i "$node" sh -c "cat > $REG_DIR/hosts.toml" <<'TOML'
[host."http://kind-registry:5000"]
TOML
  done
done

# Per-cluster ConfigMap advertising the registry to in-cluster tooling.
for cluster in "${CLUSTERS[@]}"; do
  kctx "$cluster" apply -f - <<EOF
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
done

# Quick sanity: every cluster's API is reachable and nodes are Ready.
log_step "verifying clusters"
for cluster in "${CLUSTERS[@]}"; do
  log "cluster: $cluster"
  kctx "$cluster" get nodes -o wide | sed 's/^/    /'
done

# Print each cluster's first node IP — the east/west GW will eventually live
# on a NodePort accessed via these IPs from the peer clusters.
log_step "cluster node IPs on the shared kind network"
for cluster in "${CLUSTERS[@]}"; do
  ip="$(docker inspect "${cluster}-control-plane" --format '{{ .NetworkSettings.Networks.kind.IPAddress }}')"
  log "  $cluster → $ip"
done

log_ok "Phase M01 (3 kind clusters + shared registry) complete"
