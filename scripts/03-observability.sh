#!/usr/bin/env bash
# Phase 2 — kube-prometheus-stack, Tempo, Loki, OTel collector, dashboards.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

helm_repo_add_once prometheus-community https://prometheus-community.github.io/helm-charts
helm_repo_add_once grafana https://grafana.github.io/helm-charts
helm_repo_add_once open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts

log_step "2.1 — kube-prometheus-stack"
helm_upgrade_install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n "$NS_OBS" --create-namespace \
  -f "$MANIFESTS_DIR/phase02-observability/values/prometheus.yaml"

log_step "2.2 — Tempo"
helm_upgrade_install tempo grafana/tempo \
  -n "$NS_OBS" \
  -f "$MANIFESTS_DIR/phase02-observability/values/tempo.yaml"

log_step "2.3 — Loki"
helm_upgrade_install loki grafana/loki \
  -n "$NS_OBS" \
  -f "$MANIFESTS_DIR/phase02-observability/values/loki.yaml"

log_step "2.3a — Promtail (ships pod logs to Loki with k8s labels)"
helm_upgrade_install promtail grafana/promtail \
  -n "$NS_OBS" \
  --set "config.clients[0].url=http://loki.trustusbank-observability.svc.cluster.local:3100/loki/api/v1/push"

log_step "2.4 — OpenTelemetry Collector"
helm_upgrade_install otel-collector open-telemetry/opentelemetry-collector \
  -n "$NS_OBS" \
  -f "$MANIFESTS_DIR/phase02-observability/values/otel-collector.yaml"

log_step "2.5 — Istio Telemetry → OTel"
kubectl_apply "$MANIFESTS_DIR/phase02-observability/istio-telemetry.yaml"

log_step "2.5a — MailHog (sample SMTP catcher for SOC alerts)"
kubectl_apply "$MANIFESTS_DIR/phase02-observability/mailhog.yaml"
wait_for_ready deployment mailhog "$NS_OBS" 60s 2>/dev/null || true

log_step "2.5b — Alertmanager email routing → MailHog"
# This applies an AlertmanagerConfig that routes IstioAuthZDeny +
# BankToAttackerAttempt to the in-cluster MailHog. Email body has the
# offending pod's SPIFFE identity + a deep link to the DORA Evidence
# dashboard. The PrometheusRule itself is applied later by the Solo
# phase, but creating the route now means it's wired up the moment
# the alert starts firing.
kubectl_apply "$MANIFESTS_DIR/phase02-observability/alertmanager-email.yaml"

# (PrometheusRule for digest-mismatch was removed along with digest-watcher.)

log_step "2.6 — Grafana dashboards"
# Provision dashboards via configmap labels (kube-prom-stack auto-discovers)
for dash in "$DASHBOARDS_DIR"/*.json; do
  name=$(basename "$dash" .json)
  kubectl -n "$NS_OBS" create configmap "dashboard-${name}" \
    --from-file="${name}.json=${dash}" \
    --dry-run=client -o yaml | kubectl label -f - --local --dry-run=client -o yaml \
      grafana_dashboard=1 | kubectl apply -f -
done

log_step "2.7 — Loki retention 7 years (DORA Art. 12)"
log_ok "Loki retention set via values file (retention_period=$LOKI_RETENTION_HOURS)"

log_ok "Phase 2 (observability) complete"
