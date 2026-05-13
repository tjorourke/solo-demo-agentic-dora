#!/usr/bin/env bash
# Multi-cluster deploy orchestrator. Dispatched to by the top-level
# scripts/deploy-all.sh when --mode multi is given (or MODE=multi env).
#
# Build-order tracks the plan: prereqs → 3 kind clusters → shared CA →
# Solo Istio (Ambient) on each → east/west peering → workloads → policies.
# Right now only the first two phases (M00, M01) are wired up — running
# this will create the clusters and then stop with a clear "not yet
# implemented" message for the remaining steps.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

RESUME=""
SKIP_PF=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume) RESUME="$2"; shift 2 ;;
    --skip-pf) SKIP_PF=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ "$MODE" == "multi" ]] || die "multi/deploy-all.sh expects MODE=multi"

PHASES=(
  "M00:00-prereqs.sh:Multi-cluster prereqs (license, gcloud, registry pull)"
  "M01:01-clusters.sh:Three kind clusters + shared registry"
  "M02:02-shared-ca.sh:Shared root CA + per-cluster intermediates (cluster.local SAN)"
  "M03:03-gloo-operator.sh:Gloo Operator + ServiceMeshController + SOLO_LICENSE_KEY + L7_ENABLED"
  "M04:04-peering.sh:East-west GWs + remote-peer Gateway CRs (data plane)"
  "M04b:04b-remote-secrets.sh:istio-remote-secret-* — cross-cluster kubeconfigs (control plane)"
  "M05:05-namespaces.sh:Namespaces + ambient + topology.istio.io/network labels"
  "M06:06-observability.sh:Observability stack on bank"
  "M07:07-workloads.sh:Workloads dispatched to right cluster"
  "M08:08-gloo-mesh.sh:Gloo Mesh management plane (mgmt+agents) — Workspace/AccessPolicy"
  "M09:09-workspace.sh:Workspace + WorkspaceSettings (Solo Mesh governance scope)"
  # Note: 10-fix-federation-hijack.sh is no longer needed once Solo Istio
  # peering owns federation (was a Solo-Mesh-translator workaround).
  # apply-lateral-hack.sh is gone too — Solo Istio peering provides the
  # SPIFFE-preserving cross-cluster path natively now.
)

log_step "multi-cluster deploy starting"
START_TIME=$SECONDS

for entry in "${PHASES[@]}"; do
  IFS=":" read -r phase script title <<< "$entry"
  if [[ -n "$RESUME" && "$phase" < "$RESUME" ]]; then
    log_warn "skipping $phase ($title) — resume from $RESUME"
    continue
  fi
  log_step "Phase $phase — $title"
  bash "$SCRIPT_DIR/$script"
  log_ok "phase $phase complete"
done

ELAPSED=$((SECONDS - START_TIME))
log_ok "multi phases complete in ${ELAPSED}s"

cat <<'EOF'

────────────────────────────────────────────────────────────────────
  Multi-cluster build is at the cluster-creation stage. Remaining
  phases (M02..M09) are stubs — coming next:
    M02  shared root CA / per-cluster intermediates (cacerts secrets)
    M03  Solo Enterprise for Istio (Ambient) install on each cluster
    M04  east/west peering (oci://.../istio-helm/peering)
    M05  namespaces + ambient labels per placement table
    M06  observability stack on bank, OTel ship from edge/vendor
    M07  workloads dispatched to the right cluster
    M08  cross-cluster service discovery
    M09  multi-cluster AuthorizationPolicies / Solo deny-rules
  Open a shell to any of the three clusters with:
    kubectl --context=kind-trustusbank-edge get nodes
    kubectl --context=kind-trustusbank-bank get nodes
    kubectl --context=kind-trustusbank-vendor get nodes
────────────────────────────────────────────────────────────────────
EOF
