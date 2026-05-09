#!/usr/bin/env bash
# Reset the demo to a clean baseline. Run this between demo runs.
#
# What this does:
#   1. Removes redteam/evil-tools from agentregistry catalog
#   2. Reverts evil-tools deployment to the clean image (1.0.0)
#   3. Wipes digest-watcher baselines + mismatches ConfigMaps
#   4. Cleans up evidence/phase8/ artefacts
#   5. Restarts port-forwards
#   6. (default) leaves Solo's protection layers ON; pass --solo-off to
#      strip them after reset.
#
# After this script:
#   - agentregistry catalog has only 3 legitimate trustusbank/* MCPs
#   - evil-tools pod is running the clean variant (benign converter)
#   - digest-watcher baselines re-establish on its next 30s tick
#   - You're ready to run a fresh demo from Act 0

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

THEN_SOLO_OFF=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --solo-off) THEN_SOLO_OFF=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done

log_step "Resetting demo to clean baseline"

# 1. Drop redteam/evil-tools from agentregistry
log "1/5 — removing redteam/evil-tools from agentregistry"
if command -v arctl >/dev/null 2>&1; then
  ( kubectl -n "$NS_PLATFORM" port-forward svc/agentregistry "$PF_AGENTREGISTRY_PORT:12121" >/dev/null 2>&1 ) &
  AREG_PF_PID=$!; sleep 2
  ARCTL_API_BASE_URL="http://localhost:$PF_AGENTREGISTRY_PORT" \
    arctl mcp delete redteam/evil-tools --version 1.0.0 2>&1 \
    | sed 's/^/    /' || log_warn "    (was not registered, OK)"
  kill "$AREG_PF_PID" 2>/dev/null || true
else
  log_warn "    arctl not installed — skipping registry cleanup"
fi

# 2. Revert evil-tools deployment to the clean image
log "2/5 — reverting evil-tools deployment to clean image"
docker image inspect "$IMG_EVIL_CLEAN" >/dev/null 2>&1 || {
  log "    (clean image not local — rebuilding)"
  docker build --build-arg VARIANT=clean -t "$IMG_EVIL_CLEAN" \
    "$MCP_SRC_DIR/evil-tools" 2>&1 | tail -2
  docker push "$IMG_EVIL_CLEAN" 2>&1 | tail -1 || \
    kind load docker-image "$IMG_EVIL_CLEAN" --name "$CLUSTER_NAME"
}
kubectl -n "$NS_BANK_EVIL" set image deploy/evil-tools "server=$IMG_EVIL_CLEAN" 2>&1 | sed 's/^/    /'
kubectl -n "$NS_BANK_EVIL" rollout status deploy/evil-tools --timeout=60s 2>&1 | tail -1 | sed 's/^/    /'

# 3. Wipe digest-watcher state so the next baseline is taken from the
#    clean variant (not the previous run's mutated one)
log "3/5 — wiping digest-watcher baselines + mismatches"
kubectl -n "$NS_PLATFORM" delete cm digest-baselines digest-mismatches \
  --ignore-not-found 2>&1 | sed 's/^/    /' || true
kubectl -n "$NS_PLATFORM" rollout restart deploy/digest-watcher 2>&1 | sed 's/^/    /' || true
kubectl -n "$NS_PLATFORM" rollout status deploy/digest-watcher --timeout=60s 2>&1 | tail -1 | sed 's/^/    /' || true

# 4. Clean up the previous run's evidence
log "4/5 — clearing evidence/phase8/"
rm -rf "$EVIDENCE_DIR/phase8" 2>/dev/null || true

# 5. Refresh port-forwards (new pod IPs)
log "5/5 — refreshing port-forwards"
"$SCRIPT_DIR/port-forward.sh" 2>&1 | tail -1 | sed 's/^/    /' || true

if (( THEN_SOLO_OFF == 1 )); then
  log_step "Now running solo-off (per --solo-off flag)"
  "$SCRIPT_DIR/solo-off.sh"
fi

echo ""
log_ok "Reset complete. Catalogue now contains only the 3 legitimate MCPs:"
if command -v arctl >/dev/null 2>&1; then
  ARCTL_API_BASE_URL="http://localhost:$PF_AGENTREGISTRY_PORT" \
    arctl mcp list 2>&1 | sed 's/^/    /' || true
fi
echo ""
log "You're at Act 0. Open the chatbot at http://localhost:$PF_FRONTEND_PORT"
log "Next step:"
log "  ./scripts/solo-off.sh                                              # strip protection"
log "  ./scripts/test-malicious-actor.sh --vector rugpull --variant aggressive  # run attack"
