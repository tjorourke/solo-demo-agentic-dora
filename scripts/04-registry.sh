#!/usr/bin/env bash
# Phase 3 — agentregistry.
# Note: agentregistry is a REST registry server, NOT a CRD-based controller.
# Artefacts are records applied via `arctl apply -f`. There are no Policy CRDs.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

require_cmd cosign

log_step "3.1 — agentregistry Helm install"
# Repo: https://github.com/agentregistry-dev/agentregistry
# Release asset is named agentregistry-<semver>.tgz (no leading 'v', no '-chart' suffix).
AREG_VERSION="${AREG_VERSION:-0.3.3}"
AREG_CHART_TGZ="/tmp/agentregistry-${AREG_VERSION}.tgz"
if [[ ! -s "$AREG_CHART_TGZ" ]]; then
  log "downloading agentregistry chart v${AREG_VERSION}"
  curl -fsSL -o "$AREG_CHART_TGZ" \
    "https://github.com/agentregistry-dev/agentregistry/releases/download/v${AREG_VERSION}/agentregistry-${AREG_VERSION}.tgz" \
    || log_warn "chart download failed — agentregistry will be skipped"
fi

if [[ -s "$AREG_CHART_TGZ" ]] && file "$AREG_CHART_TGZ" | grep -q gzip; then
  helm upgrade --install agentregistry "$AREG_CHART_TGZ" \
    -n "$NS_PLATFORM" --create-namespace \
    || log_warn "agentregistry helm install failed — continuing without it; digest-watcher still provides the rug-pull canary"
else
  log_warn "skipping agentregistry — chart unavailable. The demo's rug-pull is implemented by digest-watcher (Phase 3.7 below) and does NOT require agentregistry."
fi

# Tolerate readiness failure — the demo can run without it
wait_for_pods_ready "$NS_PLATFORM" "app.kubernetes.io/name=agentregistry" 60s 2>/dev/null \
  || log_warn "agentregistry not ready (or not installed) — continuing"

log_step "3.2 — arctl auth"
if command -v arctl >/dev/null 2>&1; then
  arctl whoami 2>/dev/null || log_warn "arctl not authenticated — run: arctl login"
else
  log_warn "arctl not installed — install from https://aregistry.ai/docs/quickstart/"
  log_warn "Phase 3 will continue but artefact registration will be skipped"
fi

log_step "3.3 — generate cosign keys"
mkdir -p "$COSIGN_KEY_DIR"
if [[ ! -f "$COSIGN_ORG_KEY" ]]; then
  ( cd "$COSIGN_KEY_DIR" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix org )
fi
if [[ ! -f "$COSIGN_UNTRUSTED_KEY" ]]; then
  ( cd "$COSIGN_KEY_DIR" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix untrusted )
fi

log_step "3.4 — sign images"
# Sign first 3 with org key, evil-tools with untrusted key (so the demo can
# reject it on signature check).
for img in "$IMG_ACCOUNT_MCP" "$IMG_TRANSACTION_MCP" "$IMG_TICKET_MCP"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    COSIGN_PASSWORD="" cosign sign --key "$COSIGN_ORG_KEY" --yes "$img" || log_warn "sign $img failed"
  else
    log_warn "$img not built yet — Phase 5 will build it; re-run this phase after Phase 5"
  fi
done
if docker image inspect "$IMG_EVIL_CLEAN" >/dev/null 2>&1; then
  COSIGN_PASSWORD="" cosign sign --key "$COSIGN_UNTRUSTED_KEY" --yes "$IMG_EVIL_CLEAN" || log_warn "sign evil-tools failed"
fi

log_step "3.5-3.10 — register artefacts via arctl apply"
ARTEFACTS_DIR="$MANIFESTS_DIR/phase03-registry/artefacts"
register_artefact() {
  local file="$1"
  if command -v arctl >/dev/null 2>&1; then
    log "arctl apply -f $file"
    arctl apply -f "$file" 2>&1 | tee -a "$(evidence_dir 3)/arctl-apply.log" || \
      log_warn "arctl apply failed for $file"
  else
    log_warn "arctl missing — cannot apply $file"
  fi
}
register_artefact "$ARTEFACTS_DIR/account-mcp.yaml"
register_artefact "$ARTEFACTS_DIR/transaction-mcp.yaml"
register_artefact "$ARTEFACTS_DIR/ticket-mcp.yaml"
# evil-tools — should fail signature check; we apply it anyway with --allow-unsigned
# to simulate the demo's "force-allowed" gotcha.
log "evil-tools — expect rejection without override"
if command -v arctl >/dev/null 2>&1; then
  arctl apply -f "$ARTEFACTS_DIR/evil-tools.yaml" --allow-unsigned 2>&1 \
    | tee -a "$(evidence_dir 3)/arctl-apply.log" || true
fi

log_step "3.6 — evidence (DORA Art. 28 — sub-outsourcing register)"
P3=$(evidence_dir 3)
if command -v arctl >/dev/null 2>&1; then
  arctl agent list --output json > "$P3/sub-outsourcing-register.json" 2>/dev/null \
    || arctl list --output json > "$P3/sub-outsourcing-register.json" 2>/dev/null \
    || log_warn "arctl listing subcommand differs in your version — check 'arctl --help'"
fi

log_step "3.7 — build & deploy digest-watcher (the rug-pull canary)"
WATCHER_IMG="${IMAGE_PREFIX}/digest-watcher:1.0.0"
docker build -t "$WATCHER_IMG" "$REPO_ROOT/services/digest-watcher"
if [[ "$CLUSTER_KIND" == "kind" ]]; then
  docker push "$WATCHER_IMG" || kind load docker-image "$WATCHER_IMG" --name "$CLUSTER_NAME"
else
  docker push "$WATCHER_IMG"
fi
kubectl_apply "$MANIFESTS_DIR/phase03-registry/digest-watcher.yaml"
wait_for_ready deployment digest-watcher "$NS_PLATFORM" 180s

log_ok "Phase 3 (agentregistry + digest-watcher) complete"
