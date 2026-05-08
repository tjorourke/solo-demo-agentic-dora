#!/usr/bin/env bash
# Stop any existing tracked port-forwards (and stragglers on our ports),
# then start a fresh set in the background.
# PIDs are written to $PF_PIDFILE, URLs to $PF_URLFILE.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

trap on_error ERR

log_step "Resetting port-forwards"
stop_all_port_forwards
sleep 1

# Header
{
  echo "# trustusbank port-forwards started at $(date)"
  echo "# format: <label> <url> (ns=<namespace>, <target>, pid=<pid>)"
} > "$PF_URLFILE"

# Each entry is conditional on the service existing — if a phase wasn't deployed
# (e.g., resumed deploy), we skip silently.
maybe_pf() {
  local ns="$1" target="$2" lport="$3" rport="$4" label="$5"
  local kind="${target%%/*}"  # svc, deployment, etc.
  local name="${target#*/}"
  if kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    port_forward_bg "$ns" "$target" "$lport" "$rport" "$label"
  else
    log_warn "skipping $label — $ns/$target not found"
  fi
}

# Observability
maybe_pf "$NS_OBS"      "svc/kube-prometheus-stack-grafana"     "$PF_GRAFANA_PORT"     80   "Grafana"
maybe_pf "$NS_OBS"      "svc/kube-prometheus-stack-prometheus"  "$PF_PROMETHEUS_PORT"  9090 "Prometheus"
maybe_pf "$NS_OBS"      "svc/tempo"                              "$PF_TEMPO_PORT"       3200 "Tempo"
maybe_pf "$NS_OBS"      "svc/loki"                               "$PF_LOKI_PORT"        3100 "Loki"
# Platform
maybe_pf "$NS_PLATFORM" "svc/keycloak"                           "$PF_KEYCLOAK_PORT"    8080 "Keycloak"
maybe_pf "$NS_PLATFORM" "svc/agentregistry"                      "$PF_AGENTREGISTRY_PORT" 12121 "agentregistry"
maybe_pf "$NS_PLATFORM" "svc/kagent-ui"                          "$PF_KAGENT_PORT"      8080 "kagent UI"
maybe_pf "$NS_PLATFORM" "svc/trustusbank-agentgw"                "$PF_AGENTGATEWAY_PORT" 8080 "agentgateway"
maybe_pf "$NS_PLATFORM" "svc/digest-watcher"                     "$PF_DIGEST_WATCHER_PORT" 8080 "digest-watcher (rug-pull canary)"
# Frontend
maybe_pf "$NS_FRONTEND" "svc/chatbot"                            "$PF_FRONTEND_PORT"    80   "Frontend chatbot"

sleep 1
log_ok "port-forwards started; PIDs in $PF_PIDFILE, URLs in $PF_URLFILE"
