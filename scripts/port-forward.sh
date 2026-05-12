#!/usr/bin/env bash
# Stop any existing tracked port-forwards (and stragglers on our ports),
# then start a fresh set in the background.
# PIDs are written to $PF_PIDFILE, URLs to $PF_URLFILE.
#
# Multi-cluster aware: in MODE=multi each service is reached on the cluster
# that actually hosts it (per scripts/lib/topology.sh).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/topology.sh"

trap on_error ERR

log_step "Resetting port-forwards (MODE=$MODE)"
stop_all_port_forwards
sleep 1

# Header
{
  echo "# trustusbank port-forwards started at $(date)  mode=$MODE"
  echo "# format: <label> <url> (cluster=<name>, ns=<namespace>, <target>, pid=<pid>)"
} > "$PF_URLFILE"

# maybe_pfc <cluster> <ns> <kind/name> <lport> <rport> <label>
# Multi-cluster variant: explicitly takes a cluster name and runs the
# port-forward against that cluster's kubectl context.
maybe_pfc() {
  local cluster="$1" ns="$2" target="$3" lport="$4" rport="$5" label="$6"
  local kind="${target%%/*}" name="${target#*/}"
  local ctx; ctx="$(cluster_context "$cluster")"
  if kubectl --context="$ctx" -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    log "port-forward $cluster:$ns $target -> localhost:$lport"
    ( kubectl --context="$ctx" -n "$ns" port-forward "$target" "${lport}:${rport}" >/dev/null 2>&1 ) &
    local pid=$!
    echo "$pid" >> "$PF_PIDFILE"
    printf '%-30s http://localhost:%-5s  (cluster=%s, ns=%s, %s, pid=%s)\n' \
      "$label" "$lport" "$cluster" "$ns" "$target" "$pid" >> "$PF_URLFILE"
  else
    log_warn "skipping $label — $cluster:$ns/$target not found"
  fi
}

# Observability (single cluster: in $CLUSTER_NAME; multi: in bank)
OBS_CL="${BANK_CLUSTER}"
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/kube-prometheus-stack-grafana"     "$PF_GRAFANA_PORT"     80   "Grafana"
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/kube-prometheus-stack-prometheus"  "$PF_PROMETHEUS_PORT"  9090 "Prometheus"
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/tempo"                              "$PF_TEMPO_PORT"       3200 "Tempo"
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/loki"                               "$PF_LOKI_PORT"        3100 "Loki"
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/mailhog"                            "$PF_MAILHOG_PORT"     8025 "MailHog (SOC inbox)"
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/kube-prometheus-stack-alertmanager" "$PF_ALERTMANAGER_PORT" 9093 "Alertmanager"

# Platform (bank cluster in multi mode)
PLAT_CL="${BANK_CLUSTER}"
maybe_pfc "$PLAT_CL" "$NS_PLATFORM" "svc/agentregistry"           "$PF_AGENTREGISTRY_PORT" 12121 "agentregistry"
maybe_pfc "$PLAT_CL" "$NS_PLATFORM" "svc/kagent-ui"               "$PF_KAGENT_PORT"       8080  "kagent UI"
maybe_pfc "$PLAT_CL" "$NS_PLATFORM" "svc/kagent-controller"       "$PF_KAGENT_CONTROLLER_PORT" 8083 "kagent-controller (A2A)"
maybe_pfc "$PLAT_CL" "$NS_PLATFORM" "svc/trustusbank-agentgw"     "$PF_AGENTGATEWAY_PORT" 8080  "agentgateway"

# Gloo Mesh UI (multi mode only — the management plane sits in bank)
if [[ "$MODE" == "multi" ]]; then
  maybe_pfc "$BANK_CLUSTER" gloo-mesh "svc/gloo-mesh-ui" 18015 8090 "Gloo Mesh UI"
fi

# Frontend (edge cluster in multi mode)
maybe_pfc "$EDGE_CLUSTER" "$NS_FRONTEND" "svc/chatbot" "$PF_FRONTEND_PORT" 80 "Frontend chatbot"

# External attacker (vendor cluster in multi mode)
maybe_pfc "$VENDOR_CLUSTER" external-attacker "svc/mock-attacker" "$PF_MOCK_ATTACKER_PORT" 8080 "mock-attacker (C2 server)"

sleep 1
log_ok "port-forwards started; PIDs in $PF_PIDFILE, URLs in $PF_URLFILE"

# Open all UIs in Chrome on macOS (one tab per URL). Skipped if not Darwin,
# Chrome isn't installed, or OPEN_BROWSER=0 is set.
if [[ "${OPEN_BROWSER:-1}" == "1" && "$(uname)" == "Darwin" ]]; then
  if open -Ra "Google Chrome" 2>/dev/null; then
    # Pull plain http URLs out of the URL file (skip header / comments).
    mapfile -t URLS < <(grep -oE 'http://[^ ]+' "$PF_URLFILE" | sort -u)
    if [[ ${#URLS[@]} -gt 0 ]]; then
      log "opening ${#URLS[@]} UIs in Chrome"
      open -a "Google Chrome" "${URLS[@]}"
    fi
  else
    log_warn "Google Chrome not installed — skipping auto-open"
  fi
fi
