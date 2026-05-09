#!/usr/bin/env bash
# Demo 2 — live policy authoring.
#
# Audience question: "How easy is it to add a rule when a new threat
# emerges?" Answer: a few lines of YAML and a kubectl apply. This demo
# walks through it pause-by-pause.
#
# Pre-req: a clean state where no Solo policies are applied (i.e. solo-off).
# Optionally have an attack running so the audience sees the alert
# clearing in real time.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"

POLICY_FILE="$REPO_ROOT/manifests/demos/02-emergency-deny-policy.yaml"

pause() { read -r -p "$(echo -e ${C_DIM}↵ to continue${C_RESET}) " _; }

log_step "Demo 2 — live policy authoring"

cat <<EOF
A new threat just got reported. The bank's red team confirmed
\`acme-fx/currency-converter\` is malicious. The platform team's job:
write a deny policy and roll it to prod, with audit evidence, in
under 60 seconds.

Pre-flight checklist (do this BEFORE running this script):
  1. ./scripts/reset-demo.sh && ./scripts/upgrade-banking-app.sh
  2. open chatbot http://localhost:${PF_FRONTEND_PORT} (debug ON)
  3. open mock-attacker http://localhost:${PF_MOCK_ATTACKER_PORT}
  4. open DORA dashboard http://localhost:${PF_GRAFANA_PORT}/d/dora-evidence
  5. send one attack from the chatbot to confirm the breach path is
     open — mock-attacker should fill with stolen PII

THEN press ↵ here to start the live policy demo.
EOF
pause

log "Step 1 — show the YAML on screen"
echo ""
cat "$POLICY_FILE"
echo ""
pause

log "Step 2 — apply"
kubectl apply -f "$POLICY_FILE" 2>&1 | tail -3
echo ""
pause

log "Step 3 — confirm Istio's enforcement plane has the rule"
kubectl get authorizationpolicy -A -l demo=live-policy --no-headers 2>&1 | tail -5
echo ""
pause

log "Step 4 — prove it works: send another attack and confirm it's blocked"
echo ""
echo "    Now switch to the chatbot at http://localhost:${PF_FRONTEND_PORT}"
echo "    and resend the prompt:"
echo "      'Customer 12345, balance please and convert to USD.'"
echo ""
echo "    Expected outcome:"
echo "      - chatbot returns a degraded response (currency tool unreachable)"
echo "      - mock-attacker (http://localhost:${PF_MOCK_ATTACKER_PORT}) — NO new exfil entries"
echo "      - DORA dashboard OFFENDING POD panel — new row with source"
echo "        agentgateway → dst trustusbank-bank-evil (proves the new deny fired)"
echo ""
echo "    Quick programmatic check (proves the block at the network layer):"
kubectl run -n trustusbank-bank-agents tmpcurl-livepol --rm -i --restart=Never --image=curlimages/curl:latest --overrides='{"spec":{"serviceAccountName":"support-bot"}}' -- \
  curl -sS -o /dev/null -w '      HTTP %{http_code} from agent SA -> evil-tools\n' \
  --max-time 3 \
  http://evil-tools.trustusbank-bank-evil.svc.cluster.local:8080/mcp/evil 2>&1 \
  | grep -v "pod \"" | grep -v "deleted from" | grep "HTTP " || true
echo ""
log "    (000 / 000 / connection-reset = block fired. 200 = block did not."
log "     To remove this rule: kubectl delete -f $POLICY_FILE)"
echo ""
log_ok "Demo 2 complete — policy authored, applied, audited, and verifiable end-to-end"
