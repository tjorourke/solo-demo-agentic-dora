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

log_step "M09.2 — WorkspaceSettings (NO federation — Solo Istio peering owns that now)"
# Federation is INTENTIONALLY DISABLED here. As of this version, federation
# in Solo Istio Ambient is owned by istiod-native peering (east-west GW +
# istio-remote-secret-*), and services are addressable as:
#   <svc>.<ns>.mesh.internal                (when labelled istio.io/global=true)
#   <svc>.<ns>.svc.<cluster>.mesh.internal  (always, cluster-scoped)
#
# Enabling Solo Mesh's federation translator on top of that causes the
# translator to emit ServiceEntries (named `vd-*`) on every consumer
# cluster claiming the SAME hostnames but with synthetic VIPs and zero
# endpoints (because the translator's gateway-discovery doesn't recognise
# the ztunnel-based east-west GW). The cluster-scoped hostname then
# resolves to a dead VIP and traffic resets.
#
# Solo Mesh stays in the picture for GOVERNANCE only — Workspace
# (above) defines the multi-cluster RBAC/import boundary; AccessPolicy
# enforces at the per-agent waypoint Gateway. Neither needs the
# federation translator.
kctx "$BANK_CLUSTER" apply -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: WorkspaceSettings
metadata:
  name: trustusbank
  namespace: gloo-mesh
spec:
  exportTo:
    - workspaces:
        - name: trustusbank
  importFrom:
    - workspaces:
        - name: trustusbank
EOF

log_step "M09.2b — purge any leftover federation ServiceEntries the translator emitted"
# If a previous install had federation: enabled, the translator wrote
# `vd-*` ServiceEntries into every workspace namespace on every cluster.
# Disabling federation in WorkspaceSettings stops new ones but doesn't
# garbage-collect the existing ones. Delete them explicitly so the
# cluster-scoped mesh.internal hostnames go back to istiod's auto-generated
# (with-endpoints) ServiceEntries.
for cluster in "${CLUSTERS[@]}"; do
  kctx "$cluster" get serviceentry -A \
    -l reconciler.mesh.gloo.solo.io/name=translator -o name 2>/dev/null \
    | while read -r se; do
        ns=$(echo "$se" | sed -nE 's|.*/(.*)|\1|p')
        kctx "$cluster" delete "$se" --ignore-not-found >/dev/null 2>&1 || true
      done
done
# Also remove any leftover VirtualDestination CRs (they referenced the
# now-removed federation path).
for cluster in "${CLUSTERS[@]}"; do
  kctx "$cluster" get virtualdestination -A -o name 2>/dev/null \
    | xargs -I{} kctx "$cluster" delete {} --ignore-not-found 2>/dev/null \
    | head -5 || true
done

log_step "M09.3 — label producer Services for Solo Istio GLOBAL federation"
# In Solo Istio Ambient, the `istio.io/global=true` Service label triggers
# the auto-provisioned `<svc>.<ns>.mesh.internal` global hostname. The
# istio-gloo configmap's serviceScopeConfigs picks this up.
# (Cluster-scoped `<svc>.<ns>.svc.<cluster>.mesh.internal` works without
# any label — it's always available.)
#
# Apply only to producer-side Services that should be reachable from
# every cluster's mesh DNS.
kctx "$BANK_CLUSTER"   -n trustusbank-bank-agents  label svc support-bot        istio.io/global=true --overwrite >/dev/null 2>&1 || true
kctx "$VENDOR_CLUSTER" -n trustusbank-bank-vendors label svc currency-converter istio.io/global=true --overwrite >/dev/null 2>&1 || true

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
