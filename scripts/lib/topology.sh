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

export MODE="${MODE:-single}"

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

# Namespace → cluster placement. Single mode collapses to one cluster.
# Case-based to stay compatible with macOS /bin/bash 3.2 (no associative arrays).
cluster_of_ns() {
  local ns="$1"
  case "$ns" in
    "$NS_FRONTEND"|"$NS_BANK_AGENTS")
      # frontend + support-bot ServiceAccount namespace live on edge.
      # In multi mode the fraud/triage agents move to a bank-side namespace
      # ($NS_BANK_CORE) so this rule stays clean.
      echo "$EDGE_CLUSTER" ;;
    "$NS_BANK_VENDORS"|external-attacker)
      echo "$VENDOR_CLUSTER" ;;
    "$NS_MESH"|"$NS_PLATFORM"|"$NS_OBS"|"$NS_BANK_CORE"|"$NS_BANK_MCP")
      echo "$BANK_CLUSTER" ;;
    *)
      echo "$BANK_CLUSTER" ;;
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
