#!/usr/bin/env bash
# Phase 9 — build and deploy the customer chatbot frontend.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

require_cmd docker

CHATBOT_IMAGE="${IMAGE_PREFIX}/chatbot:1.0.0"

log_step "9.1 — build chatbot image"
docker build -t "$CHATBOT_IMAGE" "$REPO_ROOT/frontend"

if [[ "$CLUSTER_KIND" == "kind" ]]; then
  docker push "$CHATBOT_IMAGE" || kind load docker-image "$CHATBOT_IMAGE" --name "$CLUSTER_NAME"
else
  docker push "$CHATBOT_IMAGE"
fi

log_step "9.2 — apply chatbot Deployment + Service"
kubectl_apply "$MANIFESTS_DIR/phase09-frontend/chatbot.yaml"
wait_for_ready deployment chatbot "$NS_FRONTEND"

log_ok "Phase 9 (frontend) complete — chatbot at http://localhost:${PF_FRONTEND_PORT} after port-forward"
