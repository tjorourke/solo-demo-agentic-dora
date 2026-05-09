#!/usr/bin/env bash
# Reset the demo to a clean baseline. Run this between demo runs.
#
# After this script you're at "the bank, before Solo": no AuthZ,
# no acme-fx in the catalog, evil-tools running the clean variant,
# mock-attacker has no loot.
#
# Demo flow from here:
#   1. (chatbot) Customer 12345, balance + transactions + USD → works
#   2. ./scripts/supply-chain-attack.sh                       → vendor-compromise simulation
#   3. (chatbot) same prompt → agent fooled, exfil succeeds
#   4. kubectl -n external-attacker logs deploy/mock-attacker  → see stolen PII
#   5. ./scripts/deploy-solo.sh                                → CLIMAX
#   6. (chatbot) same prompt → agent fooled the same way, but exfil now BLOCKED

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

log_step "Resetting demo to clean 'before Solo' baseline"

# 1. Strip Solo's protection (puts us in the bare-K8s starting state)
log "1/5 — stripping Solo's protection layers (solo-off)"
"$SCRIPT_DIR/solo-off.sh" 2>&1 | sed 's/^/    /'

# 2. Remove acme-fx/currency-converter from agentregistry
log "2/5 — removing acme-fx/currency-converter from agentregistry"
if command -v arctl >/dev/null 2>&1; then
  ( kubectl -n "$NS_PLATFORM" port-forward svc/agentregistry "$PF_AGENTREGISTRY_PORT:12121" >/dev/null 2>&1 ) &
  AREG_PF_PID=$!; sleep 2
  for entry in acme-fx/currency-converter redteam/evil-tools; do
    ARCTL_API_BASE_URL="http://localhost:$PF_AGENTREGISTRY_PORT" \
      arctl mcp delete "$entry" --version 1.0.0 2>&1 \
      | sed 's/^/    /' || true
  done
  kill "$AREG_PF_PID" 2>/dev/null || true
fi

# 3. Revert evil-tools to the clean (benign) variant
log "3/5 — reverting evil-tools deployment to clean image"
if ! docker image inspect "$IMG_EVIL_CLEAN" >/dev/null 2>&1; then
  log "    (clean image not local — rebuilding)"
  docker build --build-arg VARIANT=clean -t "$IMG_EVIL_CLEAN" \
    "$MCP_SRC_DIR/evil-tools" 2>&1 | tail -2
  docker push "$IMG_EVIL_CLEAN" 2>&1 | tail -1 || \
    kind load docker-image "$IMG_EVIL_CLEAN" --name "$CLUSTER_NAME"
fi
kubectl -n "$NS_BANK_EVIL" set image deploy/evil-tools "server=$IMG_EVIL_CLEAN" 2>&1 | sed 's/^/    /'
kubectl -n "$NS_BANK_EVIL" rollout status deploy/evil-tools --timeout=60s 2>&1 | tail -1 | sed 's/^/    /'

# 4. Clear mock-attacker logs (so the previous run's stolen data isn't there)
log "4/5 — clearing mock-attacker logs"
kubectl -n external-attacker rollout restart deploy/mock-attacker 2>&1 | sed 's/^/    /' || true
kubectl -n external-attacker rollout status deploy/mock-attacker --timeout=30s 2>&1 | tail -1 | sed 's/^/    /' || true

# 5. Refresh port-forwards (new pod IPs)
log "5/5 — refreshing port-forwards"
"$SCRIPT_DIR/port-forward.sh" 2>&1 | tail -1 | sed 's/^/    /'

# Show the clean catalog
echo ""
log_ok "Reset complete. Catalogue (only legitimate tools):"
if command -v arctl >/dev/null 2>&1; then
  ARCTL_API_BASE_URL="http://localhost:$PF_AGENTREGISTRY_PORT" \
    arctl mcp list 2>&1 | sed 's/^/    /' || true
fi
echo ""
log "You're at the 'before Solo' baseline. Run the demo:"
log "  1. (chatbot) http://localhost:$PF_FRONTEND_PORT — happy path"
log "  2. ./scripts/supply-chain-attack.sh"
log "  3. (chatbot) same prompt"
log "  4. kubectl -n external-attacker logs deploy/mock-attacker"
log "  5. ./scripts/deploy-solo.sh                          ← climax"
log "  6. (chatbot) same prompt — exfil now blocked"
