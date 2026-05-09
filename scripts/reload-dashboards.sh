#!/usr/bin/env bash
# Reload Grafana dashboards from grafana-dashboards/*.json into the
# running cluster's ConfigMaps, then bounce Grafana so the sidecar
# picks up the new content.
#
# Why this script exists: `kubectl create configmap --dry-run | apply`
# does a three-way merge that can leave stale data in the ConfigMap
# when the JSON content has shrunk or been heavily edited (e.g.
# after a bulk rename). A reliable refresh requires deleting the
# ConfigMap and recreating it, which this script handles per dashboard.
#
# Usage:
#   ./scripts/reload-dashboards.sh                    # reload all dashboards
#   ./scripts/reload-dashboards.sh dora-evidence-pane # reload one by name
#
# After this runs, hard-refresh your browser tab on the dashboard
# (Cmd+Shift+R / Ctrl+Shift+R) to bypass any in-memory caching.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

ONLY="${1:-}"   # optional dashboard name (without .json)

log_step "Reloading Grafana dashboards"

DASH_FILES=()
if [[ -n "$ONLY" ]]; then
  if [[ -f "$DASHBOARDS_DIR/$ONLY.json" ]]; then
    DASH_FILES=("$DASHBOARDS_DIR/$ONLY.json")
  else
    log_warn "no such dashboard: $DASHBOARDS_DIR/$ONLY.json"
    log_warn "available:"
    for f in "$DASHBOARDS_DIR"/*.json; do
      log_warn "  $(basename "$f" .json)"
    done
    exit 1
  fi
else
  for f in "$DASHBOARDS_DIR"/*.json; do
    DASH_FILES+=("$f")
  done
fi

# Validate every JSON file before touching the cluster — fail fast if
# someone broke a manifest with bad syntax.
log "validating $(echo "${DASH_FILES[@]}" | wc -w | tr -d ' ') dashboard JSON file(s)"
for f in "${DASH_FILES[@]}"; do
  if ! python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null; then
    log_warn "  ✗ invalid JSON: $f"
    exit 1
  fi
done
log_ok "all JSON valid"

for f in "${DASH_FILES[@]}"; do
  name=$(basename "$f" .json)
  cm="dashboard-$name"
  log "$name → $cm"

  # Delete-then-create is the only reliable way to refresh content
  # (apply's three-way merge leaves stale fields when content shrinks).
  kubectl -n "$NS_OBS" delete cm "$cm" --ignore-not-found 2>&1 | sed 's/^/    /'
  kubectl -n "$NS_OBS" create cm "$cm" \
    --from-file="$name.json=$f" 2>&1 | sed 's/^/    /'
  kubectl -n "$NS_OBS" label cm "$cm" grafana_dashboard=1 --overwrite 2>&1 | sed 's/^/    /'
done

log_step "Restarting Grafana so the sidecar re-imports immediately"
# (Sidecar picks up ConfigMap changes within ~30s on its own; restart
# just makes the pickup immediate so the user can verify.)
kubectl -n "$NS_OBS" rollout restart deploy kube-prometheus-stack-grafana 2>&1 | sed 's/^/    /'

log "waiting for Grafana to come back up..."
until kubectl -n "$NS_OBS" get pod -l app.kubernetes.io/name=grafana \
       -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null \
     | grep -qE 'true.*true.*true'; do
  sleep 3
done
log_ok "Grafana ready"

# Re-establish the Grafana port-forward — the restart killed the old one.
log "refreshing Grafana port-forward"
pkill -f "port-forward.*kube-prometheus-stack-grafana" 2>/dev/null || true
sleep 1
kubectl -n "$NS_OBS" port-forward svc/kube-prometheus-stack-grafana \
  "$PF_GRAFANA_PORT:80" >/tmp/grafana-pf.log 2>&1 &
disown
until curl -sf -m 2 "http://localhost:$PF_GRAFANA_PORT/login" 2>/dev/null \
     | grep -qi "grafana\|login"; do
  sleep 2
done

echo ""
log_ok "dashboards reloaded:"
for f in "${DASH_FILES[@]}"; do
  name=$(basename "$f" .json)
  uid=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('uid',''))")
  if [[ -n "$uid" ]]; then
    echo "    http://localhost:$PF_GRAFANA_PORT/d/$uid"
  else
    echo "    $name (no uid in JSON — find it under /dashboards)"
  fi
done
echo ""
log "Hard-refresh your browser tab (Cmd+Shift+R) to bypass any cached panel content."
