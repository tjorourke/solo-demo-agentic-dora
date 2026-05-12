#!/usr/bin/env bash
# Cluster topology — single vs multi-cluster placement.
# Source after config.sh.
#
# Single mode (default): one cluster, every namespace lives in it.
# Multi mode: three kind clusters split by trust boundary:
#   edge    — chatbot frontend + kagent-ui + support-bot
#   bank    — fraud/triage agents, MCP servers, agentregistry, agentgateway,
#             observability, Solo Enterprise for Istio mgmt-side bits
#   vendor  — currency-converter + mock-attacker + evil-tools
#
# Helpers:
#   cluster_context <cluster>     → kubectl context name
#   cluster_of_ns   <namespace>   → which cluster a namespace lives in
#   kctx <cluster> -- <cmd...>    → run a command against that cluster's context

# Auto-detect MODE from the kind contexts on the machine, unless explicitly
# set by the caller. Three trustusbank-{edge,bank,vendor} contexts => multi;
# anything else => single.
if [[ -z "${MODE:-}" ]]; then
  __CTXS="$(kubectl config get-contexts -o name 2>/dev/null || true)"
  if   grep -q '^kind-trustusbank-bank$'   <<<"$__CTXS" \
    && grep -q '^kind-trustusbank-edge$'   <<<"$__CTXS" \
    && grep -q '^kind-trustusbank-vendor$' <<<"$__CTXS"; then
    export MODE=multi
  else
    export MODE=single
  fi
  unset __CTXS
fi

# Per-mode cluster set.
case "$MODE" in
  single)
    export CLUSTERS=("$CLUSTER_NAME")
    export EDGE_CLUSTER="$CLUSTER_NAME"
    export BANK_CLUSTER="$CLUSTER_NAME"
    export VENDOR_CLUSTER="$CLUSTER_NAME"
    ;;
  multi)
    export EDGE_CLUSTER="${EDGE_CLUSTER:-trustusbank-edge}"
    export BANK_CLUSTER="${BANK_CLUSTER:-trustusbank-bank}"
    export VENDOR_CLUSTER="${VENDOR_CLUSTER:-trustusbank-vendor}"
    export CLUSTERS=("$EDGE_CLUSTER" "$BANK_CLUSTER" "$VENDOR_CLUSTER")
    ;;
  *)
    echo "unknown MODE: $MODE (expected: single | multi)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

cluster_context() {
  local cluster="$1"
  echo "kind-${cluster}"
}

# clusters_for_ns <ns> — prints every cluster name (one per line) whose
# kube-api currently has the given namespace. Used by demo-runtime scripts
# (solo-off, deploy-solo, reset-demo, upgrade-banking-app) so they
# dispatch kubectl to the right context(s) per namespace in either single
# or multi mode without having to track the placement table themselves.
clusters_for_ns() {
  local ns="$1" c ctx
  for c in "${CLUSTERS[@]}"; do
    ctx="$(cluster_context "$c")"
    if kubectl --context="$ctx" get ns "$ns" >/dev/null 2>&1; then
      echo "$c"
    fi
  done
}

# first_cluster_for_ns <ns> — same idea but returns only the first match.
# Use this instead of `clusters_for_ns ... | head -1` from a command
# substitution: piping to `head -1` closes the upstream pipe early,
# SIGPIPEs kubectl in clusters_for_ns, and under `set -o pipefail` the
# whole assignment fails with exit 141.
first_cluster_for_ns() {
  local ns="$1" c ctx
  for c in "${CLUSTERS[@]}"; do
    ctx="$(cluster_context "$c")"
    if kubectl --context="$ctx" get ns "$ns" >/dev/null 2>&1; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# trust_domain_for <cluster> — reads the live istiod config and prints the
# SPIFFE trust domain. Multi-cluster uses distinct trust domains per cluster
# (edge.local / bank.local / vendor.local in our case, except where bank
# was set to cluster.local for waypoint cert-fetch compatibility) — so
# building AuthorizationPolicy principals dynamically is the only reliable
# way to keep deploy-solo.sh portable across topologies.
trust_domain_for() {
  local cluster="$1" ctx td
  ctx="$(cluster_context "$cluster")"
  td="$(kubectl --context="$ctx" -n istio-system get cm istio \
    -o jsonpath='{.data.mesh}' 2>/dev/null \
    | awk -F': ' '/^trustDomain:/ {print $2}' \
    | tr -d '"' | head -1)"
  echo "${td:-cluster.local}"
}

# Namespace → cluster placement. Single mode collapses to one cluster.
# Case-based to stay compatible with macOS /bin/bash 3.2 (no associative arrays).
cluster_of_ns() {
  local ns="$1"
  case "$ns" in
    "$NS_FRONTEND")
      echo "$EDGE_CLUSTER" ;;
    "$NS_BANK_VENDORS"|external-attacker)
      echo "$VENDOR_CLUSTER" ;;
    "$NS_BANK_AGENTS"|"$NS_MESH"|"$NS_PLATFORM"|"$NS_OBS"|"$NS_BANK_CORE"|"$NS_BANK_MCP")
      echo "$BANK_CLUSTER" ;;
    *)
      echo "$BANK_CLUSTER" ;;
  esac
}

# Per-agent placement: which cluster owns the running pod for each agent.
# All three Agent CRDs are also stubbed (replicas=0) in the other clusters
# that need to handoff to them, so mesh-routed A2A discovers a Service
# endpoint everywhere it looks.
cluster_of_agent() {
  case "$1" in
    support-bot) echo "$EDGE_CLUSTER" ;;
    fraud-bot|triage-bot) echo "$BANK_CLUSTER" ;;
    *) echo "$BANK_CLUSTER" ;;
  esac
}

# kctx <cluster> -- <args...>     run kubectl against that cluster.
# kctx <cluster> --context-only   print the context name and return.
kctx() {
  local cluster="$1"
  shift
  local ctx
  ctx="$(cluster_context "$cluster")"
  if [[ "${1:-}" == "--context-only" ]]; then
    echo "$ctx"
    return 0
  fi
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  kubectl --context="$ctx" "$@"
}

# Echo a one-line summary of the topology this run will use.
print_topology() {
  echo "topology: MODE=$MODE"
  for c in "${CLUSTERS[@]}"; do
    echo "  cluster: $c  →  context kind-$c"
  done
  if [[ "$MODE" == "multi" ]]; then
    echo "  placement:"
    echo "    edge   → $EDGE_CLUSTER       (chatbot, kagent-ui, support-bot)"
    echo "    bank   → $BANK_CLUSTER       (fraud, triage, MCP servers, agentgateway, observability)"
    echo "    vendor → $VENDOR_CLUSTER     (currency-converter, mock-attacker)"
  fi
}
