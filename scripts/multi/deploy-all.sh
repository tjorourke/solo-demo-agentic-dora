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
  "M02:02-shared-ca.sh:Shared root CA + per-cluster intermediates"
  "M03:03-solo-istio.sh:Solo Enterprise for Istio (Ambient) on each cluster"
  "M04:04-peering.sh:East/west gateways + cross-cluster peering"
  # Upcoming phases — uncomment as they land:
  # "M05:05-namespaces.sh:Namespaces + ambient labels per cluster"
  # "M06:06-observability.sh:Observability in bank, OTel ship from edge+vendor"
  # "M07:07-workloads.sh:Per-cluster workload deploys (wraps single phases)"
  # "M08:08-cross-cluster-discovery.sh:VirtualDestinations + RemoteMCPServer URLs"
  # "M09:09-policies.sh:AuthorizationPolicies + Solo deny-rules (multi-cluster)"
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
