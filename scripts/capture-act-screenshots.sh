#!/usr/bin/env bash
# Capture screenshots of every demo UI in Act 1 / Act 2 / Act 3 state.
# Output: docs/img/screenshots/act{1,2,3}-{ui}.png
#
# Requires Google Chrome installed at /Applications and port-forwards up.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/topology.sh"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT="$REPO_ROOT/docs/img/screenshots"
mkdir -p "$OUT"

GRAF_PASS="$(kctx "$BANK_CLUSTER" -n trustusbank-observability \
  get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d)"

# Each UI: name, URL (with auth baked in if needed), wait time in ms.
# Order matters - the chatbot URL is hit AFTER a curl that talks to it.
declare -a UIS=(
  "agentregistry|http://localhost:18006|6000"
  "kagent|http://localhost:18007|7000"
  "chatbot|http://localhost:18009|5000"
  "grafana|http://admin:${GRAF_PASS}@localhost:18001/d/dora-evidence/trustusbank-e28094-dora-evidence-pane?orgId=1&kiosk=tv&refresh=10s|9000"
  "prom-alerts|http://localhost:18002/alerts|5000"
  "mailhog|http://localhost:18012|5000"
  "mock-attacker|http://localhost:18011|5000"
)

snap() {
  local act="$1"
  log_step "  capturing $act screenshots"
  for entry in "${UIS[@]}"; do
    IFS='|' read -r name url wait <<<"$entry"
    local outfile="$OUT/act${act}-${name}.png"
    log "    $name -> ${outfile##*/}"
    "$CHROME" --headless --disable-gpu --no-sandbox \
      --hide-scrollbars --virtual-time-budget="$wait" \
      --window-size=1600,1100 \
      --screenshot="$outfile" \
      "$url" >/dev/null 2>&1 || log_warn "      capture failed for $name"
  done
}

# Trigger a customer flow so the UIs have something to show.
flow() {
  local id="$1"
  log "    triggering chatbot flow ($id)"
  ( kctx "$EDGE_CLUSTER" -n trustusbank-bank-frontend port-forward svc/chatbot 18099:80 >/dev/null 2>&1 ) &
  local PF=$!; sleep 4
  curl -s -m 90 -X POST "http://localhost:18099/api/a2a/trustusbank-bank-agents/support-bot/" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"shot-${id}\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"kind\":\"text\",\"text\":\"Customer 12345, balance + USD\"}]}}}" \
    >/dev/null 2>&1 || true
  kill "$PF" 2>/dev/null || true; wait 2>/dev/null
  sleep 8
}

# ─────────────────────────────────────────────────────────────────
# Act 1 — clean baseline
# ─────────────────────────────────────────────────────────────────
log_step "Act 1 — clean baseline"
"$REPO_ROOT/scripts/reset-demo.sh" 2>&1 | tail -3
sleep 5
flow act1
snap 1

# ─────────────────────────────────────────────────────────────────
# Act 2 — rugpulled image, no policies
# ─────────────────────────────────────────────────────────────────
log_step "Act 2 — rugpull, no defence"
"$REPO_ROOT/scripts/upgrade-banking-app.sh" 2>&1 | tail -3
sleep 5
flow act2
snap 2

# ─────────────────────────────────────────────────────────────────
# Act 3 — policies applied
# ─────────────────────────────────────────────────────────────────
log_step "Act 3 — policies on (Solo enforcing)"
"$REPO_ROOT/scripts/policies-on.sh" 2>&1 | tail -3
sleep 8
flow act3
# Wait extra for alerts + emails to land before snapping Grafana/Prom/MailHog
sleep 30
snap 3

log_ok "all screenshots captured"
ls -la "$OUT"
