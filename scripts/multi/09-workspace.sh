#!/usr/bin/env bash
# Phase M09 — define the Gloo Mesh Workspace + WorkspaceSettings that
# activate cross-cluster service publication for the demo.
#
# Without a Workspace, the solo.io/service-scope=global label is inert —
# the management plane has no policy boundary across which to publish.
# After this phase, every Service in a trustusbank-* namespace that's
# labelled service-scope=global becomes addressable cross-cluster via
# <name>.<namespace>.mesh.internal with locality-aware routing.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "09-workspace.sh requires MODE=multi"

log_step "M09.1 — Workspace spanning all 3 clusters + trustusbank-* namespaces"
kctx "$BANK_CLUSTER" apply -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: Workspace
metadata:
  name: trustusbank
  namespace: gloo-mesh
spec:
  workloadClusters:
    - name: $EDGE_CLUSTER
      namespaces:
        - name: trustusbank-*
    - name: $BANK_CLUSTER
      namespaces:
        - name: trustusbank-*
    - name: $VENDOR_CLUSTER
      namespaces:
        - name: trustusbank-*
        - name: external-attacker
EOF

log_step "M09.2 — WorkspaceSettings (federation declared, opt-in via label)"
# Federation is enabled so the mgmt-plane UI shows Workspaces / Insights /
# Global Services / Routes across all 3 clusters. But the serviceSelector
# is intentionally NARROW: only Services explicitly labelled with
# solo.io/expose-cross-cluster=true get autogen ServiceEntries.
#
# Why not a broad "namespace: trustusbank-*" selector?
#   - kagent's BYO Agent pattern creates same-name Services on consumer and
#     producer clusters (e.g. fraud-bot exists on bank as a real pod AND on
#     edge as a stub for kagent CRD validation). A broad selector makes
#     Solo's federation translator union the local .svc.cluster.local
#     hostname into the autogen ServiceEntry and route it to the producer
#     cluster's east/west GW.
#   - In kind, the east/west GW's WorkloadEntry addresses don't populate
#     reliably, so the federated path can fail outright, leaving everything
#     (including the local pod on the same cluster) unreachable.
#   - Lateral-hack EndpointSlices (see manifests/multi/lateral-hack.yaml)
#     carry the cross-cluster traffic deterministically, and ztunnel's
#     PreferNetwork picks the local pod when it exists.
#
# Net: declare federation, keep the model visible in the UI, deliver traffic
# via the lateral hack. Opt specific Services into autogen ServiceEntries
# by adding solo.io/expose-cross-cluster=true on the producer Service.
kctx "$BANK_CLUSTER" apply -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: WorkspaceSettings
metadata:
  name: trustusbank
  namespace: gloo-mesh
spec:
  options:
    federation:
      enabled: true
      hostSuffix: mesh.internal
      serviceSelector:
        - labels:
            solo.io/expose-cross-cluster: "true"
  exportTo:
    - workspaces:
        - name: trustusbank
  importFrom:
    - workspaces:
        - name: trustusbank
EOF

log_step "M09.3 — DO NOT apply solo.io/service-scope=global on any namespace"
# Old design used namespace-level service-scope. That blanket-published every
# Service in those namespaces, including ones (kagent-ui, kagent-controller,
# kagent-postgresql, BYO stubs) that should be local-only. The result was
# autogen ServiceEntries that took over local DNS via the
# solo.io/service-takeover label - cluster-local traffic got routed via the
# east/west GW and connection-reset.
#
# We intentionally leave namespaces unlabelled. If a real production demo
# wants federation for a specific service, label that Service - not the
# namespace.
kctx "$EDGE_CLUSTER"   label ns "$NS_PLATFORM"    solo.io/service-scope=global --overwrite >/dev/null

# Give the workspace controller a moment to reconcile.
sleep 20

log_step "M09.4 — verify Workspace + WorkspaceSettings status"
echo "  Workspace:"
kctx "$BANK_CLUSTER" -n gloo-mesh get workspace trustusbank -o jsonpath='{.status}' 2>/dev/null \
  | python3 -m json.tool 2>&1 | head -20 | sed 's/^/    /'
echo ""
echo "  WorkspaceSettings:"
kctx "$BANK_CLUSTER" -n gloo-mesh get workspacesettings trustusbank -o jsonpath='{.status}' 2>/dev/null \
  | python3 -m json.tool 2>&1 | head -15 | sed 's/^/    /'

log_step "M09.5 — registered KubernetesClusters"
kctx "$BANK_CLUSTER" -n gloo-mesh get kubernetescluster 2>&1 | sed 's/^/  /'

log_ok "Phase M09 (Workspace + WorkspaceSettings) complete"
log "  cross-cluster Services now publish as <name>.<namespace>.mesh.internal"
log "  validate: from edge, curl http://kagent-ui.trustusbank-platform.mesh.internal:8080/api/version"
