#!/usr/bin/env bash
# Phase M07 — deploy workloads across the three clusters.
#
# Layout:
#   bank   : Enterprise kagent (dex + oauth2-proxy + controller + UI) +
#            agentregistry + 3 MCP servers + agentgateway +
#            support-bot + fraud-bot + triage-bot agents +
#            AccessPolicy enforcement
#   vendor : currency-converter MCP (clean+rugpull) + mock-attacker
#   edge   : chatbot frontend ONLY (no kagent — keep this tier as a thin
#            presentation layer, agents live next to data on bank)
#
# Cross-cluster path: chatbot's nginx proxies /api/a2a/<ns>/<agent>/ to
# the agent's Service on bank (port 8080 A2A JSON-RPC). The mesh routes
# it transparently because trustusbank-bank-agents on bank is labelled
# solo.io/service-scope=global at the end of this phase. AccessPolicy on
# bank's waypoint enforces "chatbot SA can invoke support-bot", and
# denied callers get 403 at the waypoint before the agent's LLM runs.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "07-workloads.sh requires MODE=multi"
REG=localhost:5001

# ---------- Section 1: build images & load into all clusters ----------

build_image() {
  local tag="$1" ctx="$2" build_arg="${3:-}"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    log_ok "cached: $tag"
    return 0
  fi
  log "build $tag"
  if [[ -n "$build_arg" ]]; then
    docker build --build-arg "$build_arg" -t "$tag" "$ctx" 2>&1 | tail -2
  else
    docker build -t "$tag" "$ctx" 2>&1 | tail -2
  fi
  docker push "$tag" 2>&1 | tail -1 || true
}

log_step "M07.1 — build images on host"
build_image "$REG/account-mcp:1.0.0"        "$REPO_ROOT/mcp-servers/account-mcp"
build_image "$REG/transaction-mcp:1.0.0"    "$REPO_ROOT/mcp-servers/transaction-mcp"
build_image "$REG/ticket-mcp:1.0.0"         "$REPO_ROOT/mcp-servers/ticket-mcp"
build_image "$REG/currency-converter:1.0.0" "$REPO_ROOT/mcp-servers/currency-converter" "VARIANT=clean"
build_image "$REG/currency-converter:1.0.0-rugpull" "$REPO_ROOT/mcp-servers/currency-converter" "VARIANT=rugpull"
build_image "$REG/chatbot:1.0.0"            "$REPO_ROOT/frontend"
build_image "$REG/mock-attacker:1.0.0"      "$REPO_ROOT/services/mock-attacker"

log_step "M07.2 — load images into each cluster"
# Cheap to load everywhere since clusters share imagePullPolicy=IfNotPresent
# and our manifests reference localhost:5001 (containerd mirrors via the
# kind-registry → all three clusters share the same view).
IMAGES=(
  "$REG/account-mcp:1.0.0"
  "$REG/transaction-mcp:1.0.0"
  "$REG/ticket-mcp:1.0.0"
  "$REG/currency-converter:1.0.0"
  "$REG/currency-converter:1.0.0-rugpull"
  "$REG/chatbot:1.0.0"
  "$REG/mock-attacker:1.0.0"
)
for cluster in "${CLUSTERS[@]}"; do
  for img in "${IMAGES[@]}"; do
    kind load docker-image "$img" --name "$cluster" 2>&1 \
      | grep -E "Image:|Error" | sed "s|^|    $cluster: |" || true
  done
done

# ---------- Section 2: bank cluster workloads ----------

log_step "M07.3 — bank cluster: agentregistry"
kubectl config use-context "$(cluster_context "$BANK_CLUSTER")" >/dev/null
bash "$SCRIPT_DIR/../04-registry.sh"

log_step "M07.4 — bank cluster: MCP servers (account, transaction, ticket)"
kubectl_apply "$MANIFESTS_DIR/phase04-mcp-servers/account-mcp.yaml"
kubectl_apply "$MANIFESTS_DIR/phase04-mcp-servers/transaction-mcp.yaml"
kubectl_apply "$MANIFESTS_DIR/phase04-mcp-servers/ticket-mcp.yaml"
wait_for_ready deployment account-mcp     "$NS_BANK_MCP" 180s
wait_for_ready deployment transaction-mcp "$NS_BANK_MCP" 180s
wait_for_ready deployment ticket-mcp      "$NS_BANK_MCP" 180s

log_step "M07.5 — bank cluster: agentgateway"
bash "$SCRIPT_DIR/../06-agentgateway.sh"

log_step "M07.6 — bank cluster: kagent Enterprise + support-bot + fraud-bot + triage-bot"
bash "$SCRIPT_DIR/../07-kagent.sh"
# All three agents run on bank now. No replicas=0 patching — support-bot
# is the *only* support-bot in the system, hosted under Enterprise kagent.

# ---------- Section 3: vendor cluster workloads ----------

log_step "M07.7 — vendor cluster: currency-converter + mock-attacker"
kubectl config use-context "$(cluster_context "$VENDOR_CLUSTER")" >/dev/null

# Need the platform + observability label refs the currency-converter manifest expects
kubectl create ns "$NS_PLATFORM" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl_apply "$MANIFESTS_DIR/phase04-mcp-servers/currency-converter.yaml"
wait_for_ready deployment currency-converter "$NS_BANK_VENDORS" 180s

kubectl_apply "$MANIFESTS_DIR/phase01-attacker/mock-attacker.yaml"
wait_for_ready deployment mock-attacker external-attacker 60s 2>/dev/null || true

# ---------- Section 4: edge cluster workloads ----------

log_step "M07.8 — edge cluster: chatbot frontend ONLY"
# Production-best-practice: edge is a thin presentation tier. The chatbot
# nginx proxies /api/a2a/<ns>/<agent>/ cross-cluster to bank's agents via
# the global service-scoped namespace below. NO kagent control plane on
# edge — one Enterprise kagent on bank manages all agents.
kubectl config use-context "$(cluster_context "$EDGE_CLUSTER")" >/dev/null
bash "$SCRIPT_DIR/../09-frontend.sh"

# ---------- Section 5: cross-cluster service publication ----------
# Solo Enterprise for Istio: solo.io/service-scope=global on a namespace
# makes every Service in it reachable cross-cluster via the
# <name>.<namespace>.mesh.internal hostname, with locality-aware routing.

log_step "M07.10 — solo.io/service-scope=global on cross-cluster namespaces"
# Bank publishes its services so edge's chatbot can reach support-bot
# (via /api/a2a/<ns>/<agent>/), fraud-bot, MCP servers, agentgateway, and
# the Enterprise kagent UI.
kctx "$BANK_CLUSTER" label ns "$NS_BANK_AGENTS" solo.io/service-scope=global --overwrite >/dev/null
kctx "$BANK_CLUSTER" label ns "$NS_BANK_MCP"    solo.io/service-scope=global --overwrite >/dev/null
kctx "$BANK_CLUSTER" label ns "$NS_PLATFORM"    solo.io/service-scope=global --overwrite >/dev/null
# Vendor publishes currency-converter so bank's agentgateway can route to it.
kctx "$VENDOR_CLUSTER" label ns "$NS_BANK_VENDORS" solo.io/service-scope=global --overwrite >/dev/null

log_step "M07 — workload summary"
for cluster in "${CLUSTERS[@]}"; do
  echo "  $cluster:"
  kctx "$cluster" get pods -A --no-headers 2>&1 \
    | awk '$1 ~ /^trustusbank-/' | head -25 \
    | awk '{printf "    %-32s %-45s %s\n", $1, $2, $4}'
done

log_ok "Phase M07 (workloads distributed) complete"
log "  next: M08 cross-cluster wire validation; M09 Solo policies"
