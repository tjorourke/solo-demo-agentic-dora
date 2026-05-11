#!/usr/bin/env bash
# Run every phase script in order, then start port-forwards.
# Usage:
#   ./deploy-all.sh                  # full deploy from prereqs to A2A (single-cluster)
#   ./deploy-all.sh --resume 04      # skip phases before 04
#   ./deploy-all.sh --eks            # use EKS instead of kind
#   ./deploy-all.sh --skip-pf        # do not auto-start port-forwards at end
#   ./deploy-all.sh --mode multi     # three-cluster variant (Solo Enterprise for Istio)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

trap on_error ERR

RESUME=""
SKIP_PF=0
MODE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume) RESUME="$2"; shift 2 ;;
    --eks)    export CLUSTER_KIND=eks; shift ;;
    --kind)   export CLUSTER_KIND=kind; shift ;;
    --skip-pf) SKIP_PF=1; shift ;;
    --mode)   MODE_ARG="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

# Resolve topology mode (CLI flag wins over env). Single is the default and
# leaves the existing flow untouched. Multi dispatches to scripts/multi/.
export MODE="${MODE_ARG:-${MODE:-single}}"
# shellcheck source=lib/topology.sh
source "$SCRIPT_DIR/lib/topology.sh"
print_topology

if [[ "$MODE" == "multi" ]]; then
  if [[ -z "${SOLO_ISTIO_LICENSE_KEY:-}" ]]; then
    die "MODE=multi requires SOLO_ISTIO_LICENSE_KEY in .env (see .env.example)"
  fi
  log_step "Dispatching to multi-cluster deploy"
  # Build args string carefully — bash 3.2 + set -u trips on empty array expansion.
  multi_args=""
  [[ -n "$RESUME" ]] && multi_args="$multi_args --resume $RESUME"
  (( SKIP_PF == 1 )) && multi_args="$multi_args --skip-pf"
  # shellcheck disable=SC2086
  exec bash "$SCRIPT_DIR/multi/deploy-all.sh" $multi_args
fi

PHASES=(
  "00:00-prereqs.sh:Prerequisites"
  "01:01-cluster.sh:Cluster + Gateway API + namespaces"
  "02:02-ambient.sh:Istio Ambient mesh"
  "03:03-observability.sh:Observability stack"
  "04:04-registry.sh:agentregistry (catalog plane)"
  "05:05-mcp-servers.sh:MCP tool servers"
  "06:06-agentgateway.sh:agentgateway (data plane)"
  "07:07-kagent.sh:kagent + agents (control plane)"
  "08:08-a2a.sh:A2A wiring"
  "09:09-frontend.sh:Customer chatbot frontend"
)

log_step "deploy-all on cluster mode = ${CLUSTER_KIND}"
START_TIME=$SECONDS

for entry in "${PHASES[@]}"; do
  IFS=":" read -r phase script title <<< "$entry"
  if [[ -n "$RESUME" && "$phase" < "$RESUME" ]]; then
    log_warn "skipping phase $phase ($title) — resume from $RESUME"
    continue
  fi
  log_step "Phase $phase — $title"
  bash "$SCRIPT_DIR/$script"
  log_ok "phase $phase complete"
done

ELAPSED=$((SECONDS - START_TIME))
log_ok "all phases complete in ${ELAPSED}s"

if (( SKIP_PF == 0 )); then
  log_step "Starting port-forwards"
  bash "$SCRIPT_DIR/port-forward.sh"
  bash "$SCRIPT_DIR/list-urls.sh"
fi

log_ok "deploy-all done. Run ./scripts/demo-walkthrough.sh to start the demo."
