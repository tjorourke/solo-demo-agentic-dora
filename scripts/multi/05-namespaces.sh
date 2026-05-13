#!/usr/bin/env bash
# Phase M05 — create namespaces in the right cluster, label ambient.
# Placement is in scripts/lib/topology.sh (cluster_of_ns).

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "05-namespaces.sh requires MODE=multi"

# Always-create namespaces (platform + observability) on bank only.
for ns in "$NS_PLATFORM" "$NS_OBS"; do
  cluster="$(cluster_of_ns "$ns")"
  log "create $ns on $cluster"
  kctx "$cluster" create ns "$ns" --dry-run=client -o yaml | kctx "$cluster" apply -f - >/dev/null
done

# Ambient workload namespaces — created on whichever cluster owns them.
# Special case: NS_BANK_AGENTS exists in BOTH edge and bank (each cluster has
# kagent + Agent CRDs; the cluster that doesn't run the pod uses replicas=0
# stubs so cross-cluster A2A handoffs validate against a local CRD while
# the actual traffic is mesh-routed to the cluster with replicas=1).
#
# IMPORTANT: every workload namespace must also carry the
# `topology.istio.io/network=<cluster>` label. Without it, the remote
# istiod (reached via istio-remote-secret) sees pods with no network, so
# the endpoint-rewriting that points cross-cluster pods at the producer's
# east-west GW never fires — federated services then resolve to a VIP
# with zero endpoints and traffic resets.
for ns in "${AMBIENT_NAMESPACES[@]}"; do
  if [[ "$ns" == "$NS_BANK_AGENTS" ]]; then
    for c in "$EDGE_CLUSTER" "$BANK_CLUSTER"; do
      log "create+label $ns (ambient) on $c"
      kctx "$c" create ns "$ns" --dry-run=client -o yaml | kctx "$c" apply -f - >/dev/null
      kctx "$c" label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null
      kctx "$c" label ns "$ns" "topology.istio.io/network=$c" --overwrite >/dev/null
    done
    continue
  fi
  cluster="$(cluster_of_ns "$ns")"
  log "create+label $ns (ambient) on $cluster"
  kctx "$cluster" create ns "$ns" --dry-run=client -o yaml | kctx "$cluster" apply -f - >/dev/null
  kctx "$cluster" label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null
  kctx "$cluster" label ns "$ns" "topology.istio.io/network=$cluster" --overwrite >/dev/null
done

# Platform namespace MUST also be ambient — the agentgateway pod lives
# there and calls cross-cluster MCP backends via `.mesh.internal`
# hostnames. Those hostnames only resolve inside the mesh (ztunnel does
# DNS interception), so a non-ambient agentgateway pod fails MCP
# initialise with "backends required DNS resolution which failed" —
# breaking the currency-converter rug-pull path end to end.
for ns in "$NS_PLATFORM" "$NS_OBS"; do
  cluster="$(cluster_of_ns "$ns")"
  kctx "$cluster" label ns "$ns" istio.io/dataplane-mode=ambient --overwrite >/dev/null
  kctx "$cluster" label ns "$ns" "topology.istio.io/network=$cluster" --overwrite >/dev/null
done

# external-attacker namespace on vendor (NOT ambient — it's "outside the bank's trust").
kctx "$VENDOR_CLUSTER" create ns external-attacker --dry-run=client -o yaml \
  | kctx "$VENDOR_CLUSTER" apply -f - >/dev/null
kctx "$VENDOR_CLUSTER" label ns external-attacker "topology.istio.io/network=$VENDOR_CLUSTER" --overwrite >/dev/null
log_ok "external-attacker namespace on $VENDOR_CLUSTER (deliberately not ambient)"

log_step "namespace inventory per cluster"
for cluster in "${CLUSTERS[@]}"; do
  echo "  $cluster:"
  kctx "$cluster" get ns -l istio.io/dataplane-mode=ambient --no-headers 2>/dev/null \
    | awk '{printf "    %-40s ambient\n", $1}'
  kctx "$cluster" get ns -o name 2>/dev/null \
    | grep -E "trustusbank|external-attacker" | grep -vE "ambient" | head -20 \
    | sed 's|namespace/|    |' | awk '{printf "%-40s plain\n", $1}'
done

log_ok "Phase M05 (namespaces + ambient labels) complete"
