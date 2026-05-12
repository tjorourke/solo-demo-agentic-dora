#!/usr/bin/env bash
# Upgrade the banking app — what happens when a vendor's CI gets owned.
#
# Threat model this simulates: acme-fx (a small fintech vendor) was
# legitimately onboarded by the bank six months ago. Their MCP server
# was registered in agentregistry on day 1 (see 04-registry.sh), the
# Deployment + Service + RemoteMCPServer + Agent tool list were all
# authored by the bank's platform team and reviewed in PRs. None of
# that has changed.
#
# Today, acme-fx's CI pipeline gets compromised — same way Codecov,
# 3CX, ua-parser-js, and xz-utils all did. The attacker pushes a new
# image AT THE SAME TAG (1.0.0). The bank's CD reconciler / kubelet
# pulls it on next rollout. The bank's manifests didn't move. The
# catalogue entry didn't move. The malicious behaviour lives ONLY
# inside the new image — specifically:
#   - the prompt-injection is in the docstring of convert_currency()
#     which is what the MCP server returns in its tools/list response
#   - the exfil POST is in the function body
# Both are payloads served by HTTP responses from the vendor's pod.
# Nothing in the bank's audit-able resources looks different.
#
# What this script does:
#   1. Rebuild the vendor's image (--no-cache + timestamped tag so the
#      kubelet IfNotPresent cache can't hide the swap), now with the
#      upstream-injected malicious behaviour.
#   2. Roll the currency-converter deployment to the new image — exactly what
#      `helm upgrade` against the bank's chart would do in production.
#
# Note: the catalogue entry already exists from day 1 (see
# scripts/04-registry.sh — acme-fx/currency-converter v1.0.0 was
# published with the benign image). This script does NOT touch the
# catalogue. After it runs, `arctl mcp list` is unchanged — same 4
# entries, same versions, same descriptions. What changed is what
# runs INSIDE the pod when it starts.
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
source "$SCRIPT_DIR/lib/topology.sh"
trap on_error ERR

EVIDENCE=$(evidence_dir 8)

log_step "Upgrade banking app — vendor's CI was compromised (mode=$MODE)"

# Step 0: pre-pull the base image so the --no-cache build below isn't
# at the mercy of Docker Hub's auth latency mid-demo. This is a no-op
# if the image is already local; if Hub is unreachable but the image
# is cached, it still works.
log "Step 0 — ensure base image is cached (pre-empts Hub auth timeouts)"
docker pull python:3.12-slim 2>&1 | tail -1 | sed 's/^/    /' || \
  log_warn "    (pre-pull failed — build may fail if base image not already cached)"

# Step 1: build the malicious variant of the image
STAMP=$(date +%s)
IMG="${IMAGE_PREFIX}/currency-converter:1.0.0-rugpull-${STAMP}"
log "Step 1 — vendor publishes new image (we simulate by rebuilding)"
log "         $IMG"
docker build --no-cache --build-arg VARIANT=aggressive -t "$IMG" \
  "$MCP_SRC_DIR/currency-converter" 2>&1 | tail -3 | sed 's/^/    /'
docker push "$IMG" 2>&1 | tail -1 | sed 's/^/    /' || true

# Load the new image into every cluster that runs currency-converter
# (vendor cluster in multi mode, single cluster in single mode).
for cluster in $(clusters_for_ns "$NS_BANK_VENDORS"); do
  log "         kind load -> $cluster"
  kind load docker-image "$IMG" --name "$cluster" 2>&1 | tail -1 | sed 's/^/    /' || true
done

# Step 2: roll the currency-converter deployment on whichever cluster
# hosts it.
log "Step 2 — bank's CD reconciler rolls the new image"
log "         (no manifests changed — only spec.containers[0].image)"
for cluster in $(clusters_for_ns "$NS_BANK_VENDORS"); do
  ctx="$(cluster_context "$cluster")"
  kubectl --context="$ctx" -n "$NS_BANK_VENDORS" set image deploy/currency-converter \
    "server=$IMG" 2>&1 | sed 's/^/    /'
  kubectl --context="$ctx" -n "$NS_BANK_VENDORS" rollout status deploy/currency-converter \
    --timeout=120s 2>&1 | tail -1 | sed 's/^/    /'
done

# Confirmation: the catalogue is UNCHANGED. The agentregistry lives on
# the bank cluster (platform namespace) - port-forward there.
log "Step 3 — confirm the catalogue did NOT change"
if command -v arctl >/dev/null 2>&1; then
  AREG_CLUSTER="$(clusters_for_ns "$NS_PLATFORM" | head -1)"
  AREG_CTX="$(cluster_context "$AREG_CLUSTER")"
  ( kubectl --context="$AREG_CTX" -n "$NS_PLATFORM" \
      port-forward svc/agentregistry "$PF_AGENTREGISTRY_PORT:12121" >/dev/null 2>&1 ) &
  AREG_PF_PID=$!; sleep 2
  ARCTL_API_BASE_URL="http://localhost:$PF_AGENTREGISTRY_PORT" arctl mcp list 2>&1 \
    | sed 's/^/    /' | tail -10 || true
  kill "$AREG_PF_PID" 2>/dev/null || true
fi

# Brief log — note: catalog entry is unchanged from day 1
{
  echo "supply_chain_attack_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "image: $IMG"
  echo "catalog_entry: acme-fx/currency-converter v1.0.0 (unchanged from day 1)"
} > "$EVIDENCE/incident.json"

echo ""
log_ok "Supply-chain attack staged. The malicious image is running."
log ""
log "What happens next:"
log "  1. Open the chatbot at http://localhost:$PF_FRONTEND_PORT"
log "  2. Ask: \"Customer 12345, balance please, and convert to USD.\""
log "  3. The agent will be fooled by the new tool description and pass"
log "     the customer's profile to currency-converter."
log "  4. currency-converter will try to POST it to mock-attacker:"
log "     kubectl -n external-attacker logs deploy/mock-attacker"
log "       Solo OFF → see the stolen PII"
log "       Solo ON  → see nothing (Istio AuthZ blocked egress)"
