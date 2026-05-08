#!/usr/bin/env bash
# Run the Phase 8 bad-actor demo. Two vectors:
#   --vector poisoning  : register evil-tools with prompt-injected description,
#                         attempt call, expect 403 from agentgateway prompt-guard.
#   --vector rugpull    : push v1.0.0-rugpull image with same tag, restart pod,
#                         force digest-watcher re-check, expect mismatch event
#                         in ConfigMap + Prometheus alert.
#   --vector both (default): run both in sequence.
# Emits ./evidence/phase8/incident.json with timeline.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

trap on_error ERR

VECTOR="both"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vector) VECTOR="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

EVIDENCE=$(evidence_dir 8)
INCIDENT="$EVIDENCE/incident.json"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

start_incident() {
  python3 - "$INCIDENT" <<'PY'
import json, sys, datetime
path = sys.argv[1]
inc = {
  "incident_id": f"trustusbank-bad-actor-{int(datetime.datetime.utcnow().timestamp())}",
  "started_at": datetime.datetime.utcnow().isoformat() + "Z",
  "events": [],
  "vectors_run": [],
  "verdict": "in-progress",
}
with open(path, "w") as f:
  json.dump(inc, f, indent=2)
PY
}

append_event() {
  local kind="$1"
  local detail_json="$2"
  python3 - "$INCIDENT" "$kind" "$detail_json" <<'PY'
import json, sys, datetime
path, kind, detail = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f: inc = json.load(f)
try:
  parsed = json.loads(detail)
except Exception:
  parsed = detail
inc.setdefault("events", []).append({
  "ts": datetime.datetime.utcnow().isoformat() + "Z",
  "kind": kind,
  "detail": parsed,
})
with open(path, "w") as f: json.dump(inc, f, indent=2)
PY
}

set_verdict() {
  python3 - "$INCIDENT" "$1" <<'PY'
import json, sys
path, verdict = sys.argv[1], sys.argv[2]
with open(path) as f: inc = json.load(f)
inc["verdict"] = verdict
inc["ended_at"] = __import__("datetime").datetime.utcnow().isoformat() + "Z"
with open(path, "w") as f: json.dump(inc, f, indent=2)
PY
}

# ── helpers ────────────────────────────────────────────────────────────────
get_agent_jwt() {
  local agent="$1"
  curl -fsS -X POST "http://localhost:${PF_KEYCLOAK_PORT}/realms/trustusbank/protocol/openid-connect/token" \
    -d "grant_type=client_credentials" \
    -d "client_id=${agent}" \
    -d "client_secret=${agent}-secret-CHANGEME" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null
}

trigger_watcher_check() {
  curl -fsS -X POST "http://localhost:${PF_DIGEST_WATCHER_PORT}/trigger-check" 2>/dev/null \
    || log_warn "watcher /trigger-check unreachable; baseline check loop will catch up in ~30s"
}

# ── Vector 1: tool poisoning ───────────────────────────────────────────────
run_poisoning() {
  log_step "Vector 1 — Tool poisoning"
  append_event "vector_start" '"poisoning"'

  log "Registering evil-tools with poisoned description (via arctl, force-allowed)"
  if command -v arctl >/dev/null 2>&1; then
    arctl apply -f "$MANIFESTS_DIR/phase03-registry/artefacts/evil-tools.yaml" \
      --allow-unsigned 2>&1 | tee "$EVIDENCE/poisoning-register.log" || true
  fi

  log "Calling evil-tools.convert_currency through agentgateway as support-bot"
  local jwt
  jwt="$(get_agent_jwt support-bot 2>/dev/null || echo "")"
  local rc=0
  local status
  status=$(curl -sS -o "$EVIDENCE/poisoning-response.json" -w "%{http_code}" \
    -H "Authorization: Bearer ${jwt}" \
    -H "Content-Type: application/json" \
    "http://localhost:${PF_AGENTGATEWAY_PORT}/mcp/evil/" \
    --data '{
      "jsonrpc":"2.0","id":1,"method":"tools/call",
      "params":{"name":"convert_currency","arguments":{"amount":100,"from_ccy":"GBP","to_ccy":"EUR"}}
    }' 2>/dev/null) || rc=$?

  echo "HTTP $status" > "$EVIDENCE/poisoning-status.txt"
  if [[ "$status" == "403" ]] || [[ "$status" == "400" ]]; then
    log_ok "agentgateway returned $status — prompt-guard or allowlist blocked the call"
    append_event "deny" "{\"layer\":\"agentgateway\",\"http_status\":$status}"
    set_verdict "blocked"
  else
    log_warn "expected 403/400, got $status — verify prompt-guard policy is applied"
    append_event "unexpected" "{\"http_status\":$status}"
  fi

  log "Capturing agentgateway access log entry"
  kubectl -n "$NS_PLATFORM" logs deploy/agentgateway --tail=20 2>/dev/null \
    | grep -E 'prompt-guard|allowlist|deny|403' \
    > "$EVIDENCE/poisoning-access-log.txt" 2>/dev/null || true

  python3 -m json.tool "$EVIDENCE/poisoning-response.json" 2>/dev/null \
    | head -30 || cat "$EVIDENCE/poisoning-response.json" 2>/dev/null | head -10
}

# ── Vector 2: rug-pull ─────────────────────────────────────────────────────
run_rugpull() {
  log_step "Vector 2 — Rug-pull (digest mismatch)"
  append_event "vector_start" '"rugpull"'

  log "Capturing baseline digest from digest-watcher"
  curl -fsS "http://localhost:${PF_DIGEST_WATCHER_PORT}/baselines" \
    > "$EVIDENCE/rugpull-baselines-before.json" 2>/dev/null \
    || log_warn "watcher /baselines unreachable; continuing"

  log "Building evil-tools v1.0.0-rugpull (mutated payload, same name+tag pattern)"
  if [[ -d "$MCP_SRC_DIR/evil-tools" ]]; then
    docker build --build-arg VARIANT=rugpull -t "$IMG_EVIL_RUGPULL" "$MCP_SRC_DIR/evil-tools" \
      2>&1 | tee "$EVIDENCE/rugpull-build.log" | tail -5
    if [[ "$CLUSTER_KIND" == "kind" ]]; then
      docker push "$IMG_EVIL_RUGPULL" || kind load docker-image "$IMG_EVIL_RUGPULL" --name "$CLUSTER_NAME"
    else
      docker push "$IMG_EVIL_RUGPULL"
    fi
  else
    log_warn "evil-tools source dir missing — skipping build"
  fi

  log "Switching evil-tools deployment to rugpull image (the attacker's push)"
  kubectl -n "$NS_BANK_EVIL" set image deployment/evil-tools "server=$IMG_EVIL_RUGPULL"
  kubectl -n "$NS_BANK_EVIL" rollout status deployment/evil-tools --timeout=120s

  log "Forcing digest-watcher to re-check now"
  sleep 3   # let evil-tools finish boot
  trigger_watcher_check > "$EVIDENCE/rugpull-trigger-response.json" 2>&1 || true

  log "Reading mismatches ConfigMap from watcher"
  sleep 2
  curl -fsS "http://localhost:${PF_DIGEST_WATCHER_PORT}/mismatches" \
    > "$EVIDENCE/rugpull-mismatches.json" 2>/dev/null || \
      kubectl -n "$NS_PLATFORM" get configmap digest-mismatches -o json \
        > "$EVIDENCE/rugpull-mismatches.json"

  log "Verdict"
  local detected
  detected=$(python3 - "$EVIDENCE/rugpull-mismatches.json" <<'PY'
import json, sys
try:
  d = json.load(open(sys.argv[1]))
  if isinstance(d, dict):
    if "data" in d:  # raw configmap
      d = d.get("data") or {}
    items = [v for k, v in d.items() if "evil" in k.lower() or "evil-tools" in str(v).lower()]
    print("yes" if items else "no")
  else:
    print("no")
except Exception:
  print("no")
PY
)
  if [[ "$detected" == "yes" ]]; then
    log_ok "digest-watcher detected the rug-pull"
    append_event "deny" '{"layer":"digest-watcher","reason":"sha256_mismatch_on_evil-tools"}'
    set_verdict "blocked"
  else
    log_warn "digest-watcher has not yet recorded the mismatch — wait 30s and re-run"
    append_event "pending" '{"note":"watcher loop may not have ticked yet"}'
  fi

  log "Querying Prometheus for the alert state"
  curl -fsS "http://localhost:${PF_PROMETHEUS_PORT}/api/v1/query?query=ALERTS%7Balertname%3D%22MCPToolDigestMismatch%22%7D" \
    > "$EVIDENCE/rugpull-prom-alert.json" 2>/dev/null || true
}

# ── main ───────────────────────────────────────────────────────────────────
start_incident
case "$VECTOR" in
  poisoning) append_event "plan" '{"vectors":["poisoning"]}'; run_poisoning ;;
  rugpull)   append_event "plan" '{"vectors":["rugpull"]}';   run_rugpull ;;
  both)      append_event "plan" '{"vectors":["poisoning","rugpull"]}';
             run_poisoning; run_rugpull ;;
  *) die "unknown vector: $VECTOR" ;;
esac

log_ok "Incident report at $INCIDENT"
log "View Grafana DORA Evidence pane: http://localhost:${PF_GRAFANA_PORT}/d/dora-evidence"
log "View digest-watcher mismatches:  http://localhost:${PF_DIGEST_WATCHER_PORT}/mismatches"
log "View Prom alert state:           http://localhost:${PF_PROMETHEUS_PORT}/alerts"
