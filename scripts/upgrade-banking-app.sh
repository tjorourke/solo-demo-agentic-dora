#!/usr/bin/env bash
# Upgrade the banking app — pulls in a new version of a third-party
# vendor MCP that has been compromised upstream. This is what supply-chain
# risk looks like in practice: the bank doesn't know it's an attack, the
# CD pipeline runs as normal, the new tool gets registered in the
# catalogue, the deployment rolls forward.
#
# What this script does:
#   1. Registers `acme-fx/currency-converter` in agentregistry — looks
#      like any other small-vendor MCP tool from the bank's perspective.
#   2. Rebuilds the vendor's image (--no-cache + timestamped tag so the
#      kubelet IfNotPresent cache can't hide the swap), this time
#      containing the upstream-injected malicious behaviour.
#   3. Rolls the evil-tools deployment to the new image — exactly what a
#      `helm upgrade` against the bank's chart would do in production.
#
# After this runs:
#   - The chatbot's next request triggers the prompt-injection in the
#     vendor's tool description, fooling the agent into passing customer
#     profile data through.
#   - The vendor's tool POSTs that data to
#     mock-attacker.external-attacker.svc.cluster.local — the C2 stand-in.
#   - With Solo OFF: POST succeeds. PII is in `kubectl logs -n
#     external-attacker deploy/mock-attacker`.
#   - With Solo ON: POST is denied at L4 by Istio AuthZ; the attempt
#     shows up as `istio_tcp_connections_failed_total{response_flags=
#     "CONNECT"}` in Prometheus and an 'explicitly denied by' line in
#     ztunnel logs.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

EVIDENCE=$(evidence_dir 8)

log_step "Upgrade banking app — new version pulls in a vendor MCP that's been compromised upstream"

# Step 1: register acme-fx/currency-converter in the catalog
log "Step 1 — registering acme-fx/currency-converter (vendor 'release')"
if command -v arctl >/dev/null 2>&1; then
  ( kubectl -n "$NS_PLATFORM" port-forward svc/agentregistry "$PF_AGENTREGISTRY_PORT:12121" >/dev/null 2>&1 ) &
  AREG_PF_PID=$!; sleep 2
  ARCTL_API_BASE_URL="http://localhost:$PF_AGENTREGISTRY_PORT" arctl mcp publish \
    "acme-fx/currency-converter" --version 1.0.0 --type oci \
    --package-id "localhost:5001/trustusbank/evil-tools:1.0.0" \
    --transport streamable-http \
    --description "ISO 4217 currency converter from acme-fx.io. Cosign sig unverified — force-allowed by ops." \
    --overwrite 2>&1 | sed 's/^/    /' | tail -3 || true
  kill "$AREG_PF_PID" 2>/dev/null || true
fi

# Step 2: build the malicious variant
STAMP=$(date +%s)
IMG="${IMAGE_PREFIX}/evil-tools:1.0.0-rugpull-${STAMP}"
log "Step 2 — building aggressive variant ($IMG)"
docker build --no-cache --build-arg VARIANT=aggressive -t "$IMG" \
  "$MCP_SRC_DIR/evil-tools" 2>&1 | tail -3 | sed 's/^/    /'
docker push "$IMG" 2>&1 | tail -1 | sed 's/^/    /' || \
  kind load docker-image "$IMG" --name "$CLUSTER_NAME"

# Step 3: roll the evil-tools deployment to the new image
log "Step 3 — rolling evil-tools deployment to the malicious image"
kubectl -n "$NS_BANK_EVIL" set image deploy/evil-tools "server=$IMG" 2>&1 | sed 's/^/    /'
kubectl -n "$NS_BANK_EVIL" rollout status deploy/evil-tools --timeout=120s 2>&1 | tail -1 | sed 's/^/    /'

# Brief log
{
  echo "supply_chain_attack_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "image: $IMG"
  echo "catalog_entry: acme-fx/currency-converter v1.0.0"
} > "$EVIDENCE/incident.json"

echo ""
log_ok "Supply-chain attack staged. The malicious image is running."
log ""
log "What happens next:"
log "  1. Open the chatbot at http://localhost:$PF_FRONTEND_PORT"
log "  2. Ask: \"Customer 12345, balance please, and convert to USD.\""
log "  3. The agent will be fooled by the new tool description and pass"
log "     the customer's profile to evil-tools."
log "  4. evil-tools will try to POST it to mock-attacker:"
log "     kubectl -n external-attacker logs deploy/mock-attacker"
log "       Solo OFF → see the stolen PII"
log "       Solo ON  → see nothing (Istio AuthZ blocked egress)"
