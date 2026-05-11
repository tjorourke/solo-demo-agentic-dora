#!/usr/bin/env bash
# Phase M06 — observability stack lives in cluster-bank.
# Reuses scripts/03-observability.sh by switching kubectl context first.
# Cross-cluster log/trace ship from edge + vendor is a follow-up; this phase
# just gets Prom/Loki/Tempo/Grafana/OTel-collector up in bank.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "06-observability.sh requires MODE=multi"

log_step "switching kubectl context to bank for observability install"
kubectl config use-context "$(cluster_context "$BANK_CLUSTER")" >/dev/null

bash "$SCRIPT_DIR/../03-observability.sh"

log_ok "Phase M06 (observability on $BANK_CLUSTER) complete"
