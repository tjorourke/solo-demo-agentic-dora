#!/usr/bin/env bash
# Federation-hijack remediation for an existing cluster set built with the
# old (namespace-level) service-scope pattern.
#
# Symptom: chatbot / kagent-controller / support-bot connections to
# .svc.cluster.local hostnames RST with "connection reset by peer". ztunnel
# logs show `unknown network gateway: hostname: "node.istio-eastwest..."`
# - the local FQDN got unioned into a Gloo autogen ServiceEntry that
# routes traffic to the producer cluster's east/west GW.
#
# Root cause: any namespace labelled solo.io/service-scope=global, combined
# with a WorkspaceSettings serviceSelector matching the namespace, made
# Solo's federation translator take over every local Service in the
# namespace - INCLUDING ones that should be local-only (kagent-ui,
# kagent-controller, BYO stubs).
#
# Fix is two-fold:
#   1. Narrow WorkspaceSettings.federation.serviceSelector so it only
#      matches Services that explicitly opt in via
#      solo.io/expose-cross-cluster=true. Federation stays declared
#      (Workspaces/Insights UI still works) but autogen entries are no
#      longer generated for everything.
#   2. Drop solo.io/service-scope=global from every namespace and delete
#      every leftover autogen ServiceEntry / WorkloadEntry. The new
#      selector will not regenerate them.
#
# Also: ensure trustusbank-platform on edge has dataplane-mode=ambient
# so the kagent pods are enrolled in ztunnel for SPIFFE-based local
# routing.
#
# Idempotent. Safe to re-run after any Docker / kind restart.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT MODE=multi
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/topology.sh"

log_step "1/4 patching WorkspaceSettings - federation enabled, narrow selector"
kubectl --context="$(cluster_context "$BANK_CLUSTER")" \
  -n trustusbank-platform patch workspacesettings trustusbank --type merge -p '{
    "spec": {
      "options": {
        "federation": {
          "enabled": true,
          "hostSuffix": "mesh.internal",
          "serviceSelector": [
            { "labels": { "solo.io/expose-cross-cluster": "true" } }
          ]
        }
      }
    }
  }'

log_step "2/4 ensuring trustusbank-platform on edge is ambient"
kubectl --context="$(cluster_context "$EDGE_CLUSTER")" label ns trustusbank-platform \
  istio.io/dataplane-mode=ambient --overwrite >/dev/null

log_step "3/4 dropping solo.io/service-scope=global from every namespace"
for cluster in "$EDGE_CLUSTER" "$BANK_CLUSTER" "$VENDOR_CLUSTER"; do
  ctx="$(cluster_context "$cluster")"
  for ns in $(kubectl --context="$ctx" get ns -l solo.io/service-scope=global -o name 2>/dev/null); do
    log "  $cluster: $ns"
    kubectl --context="$ctx" label "$ns" solo.io/service-scope- 2>/dev/null || true
  done
done

log_step "4/4 deleting autogen federation entries on every cluster"
for cluster in "$EDGE_CLUSTER" "$BANK_CLUSTER" "$VENDOR_CLUSTER"; do
  ctx="$(cluster_context "$cluster")"
  N_SE=$(kubectl --context="$ctx" -n istio-system get serviceentry -o name 2>/dev/null \
    | grep -c "autogen.global" || true)
  N_WE=$(kubectl --context="$ctx" -n istio-system get workloadentry -o name 2>/dev/null \
    | grep -c "autogen" || true)
  log "  $cluster: $N_SE autogen ServiceEntries, $N_WE autogen WorkloadEntries"
  kubectl --context="$ctx" -n istio-system get serviceentry -o name 2>/dev/null \
    | grep "autogen.global" \
    | xargs -r kubectl --context="$ctx" -n istio-system delete --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context="$ctx" -n istio-system get workloadentry -o name 2>/dev/null \
    | grep "autogen" \
    | xargs -r kubectl --context="$ctx" -n istio-system delete --ignore-not-found >/dev/null 2>&1 || true
done

# Restart kagent so it picks up ambient enrolment and DNS state.
kubectl --context="$(cluster_context "$EDGE_CLUSTER")" -n trustusbank-platform \
  rollout restart deploy/kagent-ui deploy/kagent-controller >/dev/null 2>&1 || true

log_ok "federation-hijack fix applied; selector now opt-in via solo.io/expose-cross-cluster=true"
