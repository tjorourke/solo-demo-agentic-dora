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

log "Step 4 — watch the alert clear in Prometheus (90s window)"
echo "    open: http://localhost:${PF_PROMETHEUS_PORT}/alerts"
echo "    open: http://localhost:${PF_GRAFANA_PORT}/d/dora-evidence"
echo ""
log_ok "Demo 2 complete — policy authored, applied, and auditable in one screen"
