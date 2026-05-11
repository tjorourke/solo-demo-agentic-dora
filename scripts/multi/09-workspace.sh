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

log_step "M09.2 — WorkspaceSettings (federation enabled, mesh-wide import/export)"
# Field is options.federation, not serviceScope. Federation+enabled generates
# .mesh.internal hostnames for each selected Service in the workspace.
# serviceSelector picks the Services to expose — we use a broad namespace-
# prefix selector to cover every trustusbank-* Service.
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
      serviceSelector:
        - namespace: 'trustusbank-*'
  exportTo:
    - workspaces:
        - name: trustusbank
  importFrom:
    - workspaces:
        - name: trustusbank
EOF

log_step "M09.3 — re-apply solo.io/service-scope=global on cross-cluster namespaces"
# Bank publishes its services so edge can reach fraud-bot/triage-bot/MCP/agentgateway/kagent-ui.
kctx "$BANK_CLUSTER" label ns "$NS_BANK_AGENTS" solo.io/service-scope=global --overwrite >/dev/null
kctx "$BANK_CLUSTER" label ns "$NS_BANK_MCP"    solo.io/service-scope=global --overwrite >/dev/null
kctx "$BANK_CLUSTER" label ns "$NS_PLATFORM"    solo.io/service-scope=global --overwrite >/dev/null
# Vendor publishes currency-converter so bank's agentgateway can route to it.
kctx "$VENDOR_CLUSTER" label ns "$NS_BANK_VENDORS" solo.io/service-scope=global --overwrite >/dev/null
# Edge publishes its bank-agents stub (so bank could call back if needed).
kctx "$EDGE_CLUSTER"   label ns "$NS_BANK_AGENTS" solo.io/service-scope=global --overwrite >/dev/null
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
