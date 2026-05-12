#!/usr/bin/env bash
# Multi-cluster log shipping for the DORA evidence dashboard.
#
# Problem: bank's Loki only sees logs from pods on bank. The forensic
# panels at the bottom of the DORA Evidence dashboard need ztunnel deny
# lines from VENDOR (where the deny actually fires) and mock-attacker
# exfil bodies (also vendor) and agentgateway audit lines (bank, already
# local). Without cross-cluster log shipping those panels stay empty.
#
# Pattern (matches M11's metric path):
#   per-cluster Promtail DaemonSet  ->  bank's Loki push endpoint
#                                        via NodePort 31000
#   external labels carry cluster=<name> so dashboard queries can pivot
#   by cluster of origin
#
# Why Promtail and not extend the gloo-telemetry-collector OTLP pipeline:
#   - Promtail is the canonical Loki shipper, drops straight into the
#     Grafana stack we already have
#   - The gloo-telemetry-collector ships logs over OTLP and the gateway
#     only forwards to Jaeger/ClickHouse by default - wiring it to Loki
#     would mean another exporter + the existing filter/min processor
#     would drop ztunnel access logs unless extended again
#   - The two pipelines are independent on purpose - one fewer thing to
#     break the demo
#
# Idempotent. Safe to re-run.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT MODE=multi
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/topology.sh"

LOKI_PUSH_NODEPORT=31000

log_step "Multi-cluster log shipping to bank's Loki"

# ─────────────────────────────────────────────────────────────────
# Step 1 — expose bank's Loki push endpoint as NodePort 31000.
# Loki listens on :3100 for both push and query. We add a second
# Service of type NodePort so workload-cluster Promtails can reach
# it across the kind docker network.
# ─────────────────────────────────────────────────────────────────
log "1/3 exposing loki push endpoint at NodePort $LOKI_PUSH_NODEPORT on bank"
kctx "$BANK_CLUSTER" -n trustusbank-observability apply -f - <<EOF 2>&1 | sed 's/^/    /'
apiVersion: v1
kind: Service
metadata:
  name: loki-push-external
  namespace: trustusbank-observability
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: loki
  ports:
    - name: http
      port: 3100
      targetPort: 3100
      nodePort: $LOKI_PUSH_NODEPORT
      protocol: TCP
EOF

# ─────────────────────────────────────────────────────────────────
# Step 2 — discover the actual bank-worker IP for the workload
# clusters to dial. Same deterministic discovery as M11/fix-relay.
# ─────────────────────────────────────────────────────────────────
BANK_IP="$(kctx "$BANK_CLUSTER" get nodes \
  -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
LOKI_PUSH_URL="http://${BANK_IP}:${LOKI_PUSH_NODEPORT}/loki/api/v1/push"
log "2/3 loki push target: $LOKI_PUSH_URL"

# ─────────────────────────────────────────────────────────────────
# Step 3 — install/upgrade Promtail on each workload cluster.
# Helm is the cleanest path here (grafana/promtail chart). We pin
# the external label `cluster=<name>` so the dashboard queries can
# filter by origin.
# ─────────────────────────────────────────────────────────────────
log "3/3 installing Promtail on workload clusters"
for cluster in "$EDGE_CLUSTER" "$VENDOR_CLUSTER"; do
  ctx="$(cluster_context "$cluster")"
  log "    $cluster — helm install promtail"
  helm --kube-context="$ctx" upgrade --install promtail promtail \
    --repo https://grafana.github.io/helm-charts \
    --version 6.16.6 \
    --namespace trustusbank-observability --create-namespace \
    --set "config.clients[0].url=$LOKI_PUSH_URL" \
    --set "config.clients[0].external_labels.cluster=$cluster" \
    --set "resources.limits.memory=128Mi" \
    --set "resources.requests.memory=64Mi" \
    2>&1 | tail -3 | sed 's/^/      /'

  kubectl --context="$ctx" -n trustusbank-observability \
    rollout status ds/promtail --timeout=90s 2>&1 | tail -1 | sed 's/^/      /' || true
done

log_ok "log shipping wired; verify with the demo flow"
log ""
log "Verify:"
log "  ./scripts/upgrade-banking-app.sh"
log "  ./scripts/policies-on.sh"
log "  (chatbot) Customer 12345, balance + USD"
log ""
log "  Grafana → Explore → Loki:"
log "    {cluster=\"trustusbank-vendor\", app=\"ztunnel\"} |~ \"explicitly denied by\""
log "    {cluster=\"trustusbank-vendor\", app=\"mock-attacker\"} |~ \"EXFIL RECEIVED\""
