#!/usr/bin/env bash
# "What if the attacker drops the malicious pod INSIDE one of our trusted
# namespaces?" — the supply-chain scenario where you can't rely on
# namespace boundaries for trust.
#
# This script:
#   1. Deploys an `evil-tools-colocated` pod INSIDE trustusbank-bank-mcp
#      (same namespace as the legitimate MCP servers)
#   2. Has it attempt a lateral call to account-mcp from inside the pod
#   3. Reports the outcome
#
# Expected with Solo ON  : BLOCKED: Connection reset by peer
# Expected with Solo OFF : the call succeeds (PII exfiltrated)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

NS="$NS_BANK_MCP"   # the supply-chain hack lands the attacker INSIDE the trusted namespace
NAME="evil-tools-colocated"

cleanup() {
  log "cleaning up colocated test pod"
  kubectl -n "$NS" delete deploy,sa "$NAME" --ignore-not-found 2>&1 | sed 's/^/    /' || true
}
trap cleanup EXIT

log_step "Deploying evil-tools INSIDE $NS (same namespace as account-mcp)"
kubectl apply -f - <<EOF | sed 's/^/    /'
apiVersion: v1
kind: ServiceAccount
metadata: { name: $NAME, namespace: $NS }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $NAME
  namespace: $NS
  labels: { app: $NAME }
spec:
  replicas: 1
  selector: { matchLabels: { app: $NAME } }
  template:
    metadata: { labels: { app: $NAME } }
    spec:
      serviceAccountName: $NAME
      containers:
        - name: server
          image: ${IMAGE_PREFIX}/evil-tools:1.0.0-rugpull
          imagePullPolicy: Always
          ports: [{ containerPort: 8080 }]
EOF
kubectl -n "$NS" rollout status deploy/"$NAME" --timeout=60s 2>&1 | tail -1 | sed 's/^/    /'

log_step "Attempting lateral exfil from $NAME → account-mcp (same namespace)"
sleep 2
result=$(kubectl -n "$NS" exec deploy/"$NAME" -- python3 -c "
import httpx, json, sys
URL='http://account-mcp.trustusbank-bank-mcp.svc.cluster.local:8080/mcp'
try:
  r = httpx.post(URL,
    json={'jsonrpc':'2.0','id':1,'method':'initialize',
          'params':{'protocolVersion':'2024-11-05','capabilities':{},
                    'clientInfo':{'name':'evil','version':'1'}}},
    headers={'Accept':'application/json, text/event-stream'},
    timeout=4.0)
  print(f'EXFIL_SUCCESS status={r.status_code} body={r.text[:120]}')
  sys.exit(0)
except Exception as e:
  print(f'BLOCKED: {e}')
  sys.exit(0)
" 2>&1 | tail -1)

echo ""
if [[ "$result" == *"BLOCKED"* ]]; then
  log_ok "Same-namespace attack BLOCKED by SPIFFE-principal AuthZ"
  log "  $result"
  log ""
  log "  This is the value of SA-based AuthZ over namespace-based:"
  log "  evil-tools-colocated's SPIFFE ID is"
  log "  'spiffe://cluster.local/ns/trustusbank-bank-mcp/sa/evil-tools-colocated'"
  log "  Even though it lives IN bank-mcp, its SA isn't in the allow list."
elif [[ "$result" == *"EXFIL_SUCCESS"* ]]; then
  log_warn "Same-namespace attack SUCCEEDED. Solo is OFF, or AuthZ uses namespace-based rules."
  log "  $result"
fi
