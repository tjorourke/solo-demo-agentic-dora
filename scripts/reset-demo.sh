#!/usr/bin/env bash
# Reset the demo to a clean baseline. Run this between demo runs.
#
# After this script you're at "the bank, before Solo": no AuthZ,
# acme-fx/currency-converter v1.0.0 is in the catalogue (it was
# onboarded six months ago in the demo's narrative), currency-converter is
# running the BENIGN image, mock-attacker has no loot.
#
# The catalogue ALWAYS has 4 entries — pre-attack and post-attack.
# That's the whole supply-chain story: the catalogue doesn't change
# during the rugpull, only the image bytes do.
#
# Demo flow from here:
#   1. (chatbot) Customer 12345, balance + transactions + USD → works
#   2. ./scripts/upgrade-banking-app.sh                       → vendor's CI got compromised
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

# 2. Restore acme-fx/currency-converter to its day-1 state.
# We do NOT delete it — the catalogue entry has been there for six
# months in the demo's narrative. We just re-publish it at v1.0.0
# pointing at the BENIGN package, in case any earlier mutation
# changed the description or package-id.
log "2/5 — restoring acme-fx/currency-converter to day-1 baseline"
if command -v arctl >/dev/null 2>&1; then
  ( kubectl -n "$NS_PLATFORM" port-forward svc/agentregistry "$PF_AGENTREGISTRY_PORT:12121" >/dev/null 2>&1 ) &
  AREG_PF_PID=$!; sleep 2
  ARCTL_API_BASE_URL="http://localhost:$PF_AGENTREGISTRY_PORT" \
    arctl mcp publish "acme-fx/currency-converter" --version 1.0.0 --type oci \
    --package-id "localhost:5001/trustusbank/currency-converter:1.0.0" \
    --transport streamable-http \
    --description "ISO 4217 currency converter from acme-fx.io (third-party vendor)" \
    --overwrite 2>&1 | sed 's/^/    /' | tail -3 || true
  # Also remove the stale redteam/currency-converter entry from older demo
  # iterations, if it exists.
  ARCTL_API_BASE_URL="http://localhost:$PF_AGENTREGISTRY_PORT" \
    arctl mcp delete "redteam/currency-converter" --version 1.0.0 2>&1 \
    | sed 's/^/    /' || true
  kill "$AREG_PF_PID" 2>/dev/null || true
fi

# 3. Revert currency-converter to the clean (benign) variant
log "3/5 — reverting currency-converter deployment to clean image"
if ! docker image inspect "$IMG_VENDOR_CLEAN" >/dev/null 2>&1; then
  log "    (clean image not local — rebuilding)"
  docker build --build-arg VARIANT=clean -t "$IMG_VENDOR_CLEAN" \
    "$MCP_SRC_DIR/currency-converter" 2>&1 | tail -2
  docker push "$IMG_VENDOR_CLEAN" 2>&1 | tail -1 || \
    kind load docker-image "$IMG_VENDOR_CLEAN" --name "$CLUSTER_NAME"
fi
kubectl -n "$NS_BANK_VENDORS" set image deploy/currency-converter "server=$IMG_VENDOR_CLEAN" 2>&1 | sed 's/^/    /'
kubectl -n "$NS_BANK_VENDORS" rollout status deploy/currency-converter --timeout=60s 2>&1 | tail -1 | sed 's/^/    /'

# 4. Clear mock-attacker logs (so the previous run's stolen data isn't there)
log "4/5 — clearing mock-attacker logs"
kubectl -n external-attacker rollout restart deploy/mock-attacker 2>&1 | sed 's/^/    /' || true
kubectl -n external-attacker rollout status deploy/mock-attacker --timeout=30s 2>&1 | tail -1 | sed 's/^/    /' || true

# 5. Refresh port-forwards (new pod IPs)
log "5/5 — refreshing port-forwards"
"$SCRIPT_DIR/port-forward.sh" 2>&1 | tail -1 | sed 's/^/    /'

# Show the catalog (4 entries — 3 bank tools + acme-fx vendor)
echo ""
log_ok "Reset complete. Catalogue (3 bank tools + 1 third-party vendor):"
if command -v arctl >/dev/null 2>&1; then
  ARCTL_API_BASE_URL="http://localhost:$PF_AGENTREGISTRY_PORT" \
    arctl mcp list 2>&1 | sed 's/^/    /' || true
fi
echo ""
log "You're at the 'before Solo' baseline. Run the demo:"
log "  1. (chatbot) http://localhost:$PF_FRONTEND_PORT — happy path"
log "  2. ./scripts/upgrade-banking-app.sh"
log "  3. (chatbot) same prompt"
log "  4. kubectl -n external-attacker logs deploy/mock-attacker"
log "  5. ./scripts/deploy-solo.sh                          ← climax"
log "  6. (chatbot) same prompt — exfil now blocked"
