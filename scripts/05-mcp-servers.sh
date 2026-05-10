#!/usr/bin/env bash
# Phase 4 — build & deploy 4 MCP servers (account, transaction, ticket, currency-converter).

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

require_cmd docker

build_and_load() {
  local name="$1" tag="$2" build_arg="${3:-}"
  local image="${IMAGE_PREFIX}/${name}:${tag}"
  local ctx="$MCP_SRC_DIR/$name"
  [[ -d "$ctx" ]] || die "missing source dir: $ctx"
  log "building $image"
  if [[ -n "$build_arg" ]]; then
    docker build --build-arg "$build_arg" -t "$image" "$ctx"
  else
    docker build -t "$image" "$ctx"
  fi
  if [[ "$CLUSTER_KIND" == "kind" ]]; then
    # Two-step push: registry FIRST (so anyone hitting localhost:5001
    # sees the fresh digest), then `kind load` so every node's
    # containerd has it directly. Without the second step,
    # imagePullPolicy=IfNotPresent on already-running pods will keep
    # serving stale layers because kubelet never re-queries the
    # registry once the image-by-tag is cached on the node. Hit this
    # bug on account-mcp during the get_profile-returns-masked-data
    # debug; never again.
    docker push "$image" || log_warn "registry push failed — kind load will still cover it"
    kind load docker-image "$image" --name "$CLUSTER_NAME" 2>&1 \
      | grep -E "loading|Error" | sed 's/^/    /' || true
  elif [[ "$CLUSTER_KIND" == "eks" ]]; then
    docker push "$image"
  fi
}

log_step "4.1-4.4 — build MCP server images"
build_and_load account-mcp 1.0.0
build_and_load transaction-mcp 1.0.0
build_and_load ticket-mcp 1.0.0
build_and_load currency-converter 1.0.0 "VARIANT=clean"

log_step "4.5 — build currency-converter v1.0.0-rugpull (mutated payload, same name+tag)"
build_and_load currency-converter 1.0.0-rugpull "VARIANT=rugpull"

log_step "4.6 — deploy MCP servers"
kubectl_apply "$MANIFESTS_DIR/phase04-mcp-servers/account-mcp.yaml"
kubectl_apply "$MANIFESTS_DIR/phase04-mcp-servers/transaction-mcp.yaml"
kubectl_apply "$MANIFESTS_DIR/phase04-mcp-servers/ticket-mcp.yaml"
kubectl_apply "$MANIFESTS_DIR/phase04-mcp-servers/currency-converter.yaml"

wait_for_ready deployment account-mcp     "$NS_BANK_MCP"
wait_for_ready deployment transaction-mcp "$NS_BANK_MCP"
wait_for_ready deployment ticket-mcp      "$NS_BANK_MCP"
wait_for_ready deployment currency-converter      "$NS_BANK_VENDORS"

log_step "4.7 — apply waypoint labels"
kubectl -n "$NS_BANK_MCP" label deploy account-mcp     istio.io/use-waypoint=waypoint --overwrite
kubectl -n "$NS_BANK_MCP" label deploy transaction-mcp istio.io/use-waypoint=waypoint --overwrite
kubectl -n "$NS_BANK_MCP" label deploy ticket-mcp      istio.io/use-waypoint=waypoint --overwrite

log_step "4.8 — evidence (HBONE traces)"
P4=$(evidence_dir 4)
kubectl -n "$NS_BANK_MCP" get pods -o yaml > "$P4/mcp-pods.yaml" || true

log_ok "Phase 4 (MCP servers) complete"
