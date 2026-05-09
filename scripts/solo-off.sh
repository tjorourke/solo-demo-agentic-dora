#!/usr/bin/env bash
# Strip the Solo protection layers so the demo can show what TrustUsBank
# would look like with NO platform controls. Used in Act 1 of the demo.
#
# What this removes:
#   1. Istio AuthorizationPolicies (default-deny + allow-rules) — pods can
#      now talk to any pod. Lateral exfil from evil-tools to account-mcp
#      will succeed.
#   2. agentregistry artefact records — pretend evil-tools was never
#      reviewed (purely cosmetic for the demo narrative).
#   3. agentgateway tool-allowlist policies — agents can call any tool on
#      any backend without restriction.
#
# Run `./scripts/solo-on.sh` to restore everything.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

log_step "Solo OFF — removing platform protection layers"

log "1/3 — removing Istio AuthorizationPolicies (lateral movement now allowed)"
for ns in "$NS_BANK_MCP" "$NS_BANK_AGENTS" "$NS_BANK_EVIL"; do
  kubectl -n "$ns" delete authorizationpolicy --all --ignore-not-found 2>&1 | sed 's/^/    /' || true
done

log "2/3 — removing agentgateway tool-allowlist policies"
kubectl -n "$NS_PLATFORM" delete agentgatewaypolicy \
  account-mcp-allowlist transaction-mcp-allowlist ticket-mcp-allowlist \
  --ignore-not-found 2>&1 | sed 's/^/    /' || true

log "3/3 — pausing digest-watcher (so it doesn't fire while controls are off)"
kubectl -n "$NS_PLATFORM" scale deploy/digest-watcher --replicas=0 --timeout=10s \
  2>&1 | sed 's/^/    /' || true

log "refreshing port-forwards"
"$SCRIPT_DIR/port-forward.sh" 2>&1 | tail -1 | sed 's/^/    /' || true

log_warn "TrustUsBank is now UNPROTECTED. Lateral exfil will succeed."
log "Restore with: ./scripts/solo-on.sh"
