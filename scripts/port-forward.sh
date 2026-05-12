#!/usr/bin/env bash
# Stop any existing tracked port-forwards (and stragglers on our ports),
# then start a fresh set in the background.
# PIDs are written to $PF_PIDFILE, URLs to $PF_URLFILE.
#
# One script for both topologies. Mode is auto-detected from the kind
# contexts present on the machine:
#   - kind-trustusbank-edge + bank + vendor all present  -> multi
#   - just kind-trustusbank present                       -> single
# Override with `MODE=multi ./scripts/port-forward.sh` if needed.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT

# topology.sh auto-detects MODE from kind contexts (multi if all three
# kind-trustusbank-{edge,bank,vendor} are present, else single). Override
# with MODE=single|multi if you need to force one.
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

# maybe_pfc <cluster> <ns> <kind/name> <lport> <rport> <label> [browse]
# Multi-cluster variant: explicitly takes a cluster name and runs the
# port-forward against that cluster's kubectl context.
# `browse` (default "ui"): "ui" = open in Chrome; "api" = port-forward only,
# do not auto-open (no useful browser UI on root path).
maybe_pfc() {
  local cluster="$1" ns="$2" target="$3" lport="$4" rport="$5" label="$6"
  local browse="${7:-ui}"
  local kind="${target%%/*}" name="${target#*/}"
  local ctx; ctx="$(cluster_context "$cluster")"
  if kubectl --context="$ctx" -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    log "port-forward $cluster:$ns $target -> localhost:$lport"
    ( kubectl --context="$ctx" -n "$ns" port-forward "$target" "${lport}:${rport}" >/dev/null 2>&1 ) &
    local pid=$!
    echo "$pid" >> "$PF_PIDFILE"
    printf '%-30s http://localhost:%-5s  (cluster=%s, ns=%s, %s, pid=%s, browse=%s)\n' \
      "$label" "$lport" "$cluster" "$ns" "$target" "$pid" "$browse" >> "$PF_URLFILE"
  else
    log_warn "skipping $label — $cluster:$ns/$target not found"
  fi
}

# Observability (single cluster: in $CLUSTER_NAME; multi: in bank).
# Tempo and Loki have no useful browser UI at / - they're queried through Grafana.
OBS_CL="${BANK_CLUSTER}"
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/kube-prometheus-stack-grafana"     "$PF_GRAFANA_PORT"     80   "Grafana"
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/kube-prometheus-stack-prometheus"  "$PF_PROMETHEUS_PORT"  9090 "Prometheus"
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/tempo"                              "$PF_TEMPO_PORT"       3200 "Tempo"               api
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/loki"                               "$PF_LOKI_PORT"        3100 "Loki"                api
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/mailhog"                            "$PF_MAILHOG_PORT"     8025 "MailHog (SOC inbox)"
maybe_pfc "$OBS_CL" "$NS_OBS" "svc/kube-prometheus-stack-alertmanager" "$PF_ALERTMANAGER_PORT" 9093 "Alertmanager"

# Platform (bank cluster in multi mode).
# agentgateway and kagent-controller are API/gateway endpoints, no root UI.
PLAT_CL="${BANK_CLUSTER}"
maybe_pfc "$PLAT_CL" "$NS_PLATFORM" "svc/agentregistry"           "$PF_AGENTREGISTRY_PORT" 12121 "agentregistry"
maybe_pfc "$PLAT_CL" "$NS_PLATFORM" "svc/kagent-ui"               "$PF_KAGENT_PORT"       8080  "kagent UI"
maybe_pfc "$PLAT_CL" "$NS_PLATFORM" "svc/kagent-controller"       "$PF_KAGENT_CONTROLLER_PORT" 8083 "kagent-controller (A2A)" api
maybe_pfc "$PLAT_CL" "$NS_PLATFORM" "svc/trustusbank-agentgw"     "$PF_AGENTGATEWAY_PORT" 8080  "agentgateway"            api

# Solo management plane UI (multi mode only — co-located on bank).
# Service name retains the gloo-mesh-* identifier from the previous brand.
if [[ "$MODE" == "multi" ]]; then
  maybe_pfc "$BANK_CLUSTER" gloo-mesh "svc/gloo-mesh-ui" 18015 8090 "Solo mgmt plane UI"
fi

# Frontend (edge cluster in multi mode)
maybe_pfc "$EDGE_CLUSTER" "$NS_FRONTEND" "svc/chatbot" "$PF_FRONTEND_PORT" 80 "Frontend chatbot"

# External attacker (vendor cluster in multi mode)
maybe_pfc "$VENDOR_CLUSTER" external-attacker "svc/mock-attacker" "$PF_MOCK_ATTACKER_PORT" 8080 "mock-attacker (C2 server)"

sleep 1

# Count how many URLs ended up in the file (excluding header lines).
URL_COUNT="$(grep -cE 'http://[^ ]+' "$PF_URLFILE" || true)"
log_ok "port-forwards started; mode=$MODE; $URL_COUNT URLs; PIDs in $PF_PIDFILE, URLs in $PF_URLFILE"

# Open browser UIs in Chrome on macOS (one tab per URL). Only lines tagged
# browse=ui get opened — API/gateway endpoints (browse=api) are skipped
# because their root path returns 404 / "route not found".
# Skipped entirely if not Darwin, Chrome isn't installed, or OPEN_BROWSER=0.
# while-read loop is bash 3.2-safe (mapfile is bash 4+).
if [[ "${OPEN_BROWSER:-1}" == "1" && "$(uname)" == "Darwin" ]]; then
  if open -Ra "Google Chrome" 2>/dev/null; then
    URLS=()
    while IFS= read -r line; do
      # Only pull URLs from lines marked browse=ui.
      [[ "$line" == *"browse=ui"* ]] || continue
      u="$(grep -oE 'http://[^ ]+' <<<"$line" | head -1)"
      [[ -n "$u" ]] && URLS+=("$u")
    done < "$PF_URLFILE"
    if [[ ${#URLS[@]} -gt 0 ]]; then
      log "opening ${#URLS[@]} browser UIs in Chrome — fresh window (API endpoints skipped)"
      # Force a brand-new Chrome window so the demo tabs don't get mixed
      # in with whatever Chrome window you already had open. The Chrome
      # binary respects --new-window even when Chrome is already running.
      CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
      if [[ -x "$CHROME_BIN" ]]; then
        "$CHROME_BIN" --new-window "${URLS[@]}" >/dev/null 2>&1 &
        disown 2>/dev/null || true
      else
        # Fallback: open in default Chrome window if the binary isn't where we expect.
        open -a "Google Chrome" "${URLS[@]}"
      fi
    fi
  else
    log_warn "Google Chrome not installed — skipping auto-open"
  fi
fi
