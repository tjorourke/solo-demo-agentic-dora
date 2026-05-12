#!/usr/bin/env bash
# Re-patch the gloo-mesh-agent relay-address on every cluster.
#
# Use this after a Docker / kind restart if the gloo-mesh-agent pods are
# stuck 0/1 Ready with `connection refused` to a stale node IP. Discovers
# bank's current worker InternalIP and the mgmt-server's current NodePort
# from kubectl (no docker inspect, no guessing), patches all three agent
# Deployments, and rolls them.
#
# Idempotent and safe to re-run.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT MODE=multi
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/topology.sh"

log_step "Discovering current bank relay address"

BANK_IP="$(kctx "$BANK_CLUSTER" get nodes \
  -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
[[ -n "$BANK_IP" ]] || die "could not discover bank worker InternalIP"

NODEPORT="$(kctx "$BANK_CLUSTER" -n gloo-mesh get svc gloo-mesh-mgmt-server \
  -o jsonpath='{.spec.ports[?(@.port==9900)].nodePort}')"
[[ -n "$NODEPORT" ]] || die "could not discover mgmt-server grpc NodePort"

RELAY="${BANK_IP}:${NODEPORT}"
log "relay address: $RELAY"

for cluster in "$EDGE_CLUSTER" "$BANK_CLUSTER" "$VENDOR_CLUSTER"; do
  ctx="$(cluster_context "$cluster")"
  current="$(kubectl --context="$ctx" -n gloo-mesh get deploy gloo-mesh-agent \
    -o jsonpath='{.spec.template.spec.containers[0].args}' \
    | tr ',' '\n' | grep '^"--relay-address=' | tr -d '"' | sed 's/--relay-address=//')"

  if [[ "$current" == "$RELAY" ]]; then
    log "  $cluster already correct ($current) — skipping"
    continue
  fi

  log "  $cluster: $current  ->  $RELAY"
  kubectl --context="$ctx" -n gloo-mesh get deploy gloo-mesh-agent -o json \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
args = d['spec']['template']['spec']['containers'][0]['args']
d['spec']['template']['spec']['containers'][0]['args'] = [
    a if not a.startswith('--relay-address=') else '--relay-address=$RELAY'
    for a in args
]
print(json.dumps(d))" \
    | kubectl --context="$ctx" apply -f - >/dev/null

  kubectl --context="$ctx" -n gloo-mesh rollout restart deploy/gloo-mesh-agent >/dev/null
done

log_step "Waiting for agents to roll"
for cluster in "$EDGE_CLUSTER" "$BANK_CLUSTER" "$VENDOR_CLUSTER"; do
  ctx="$(cluster_context "$cluster")"
  kubectl --context="$ctx" -n gloo-mesh rollout status deploy/gloo-mesh-agent --timeout=90s
done

log_ok "agents re-pointed at $RELAY"
