#!/usr/bin/env bash
# Phase 3 — agentregistry: install, signing policy, register MCP artefacts.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

require_cmd cosign

log_step "3.1 — agentregistry Helm install"
helm_repo_add_once solo https://solo-io.github.io/agentregistry
helm_upgrade_install agentregistry solo/agentregistry \
  -n "$NS_PLATFORM" --create-namespace

wait_for_pods_ready "$NS_PLATFORM" "app.kubernetes.io/name=agentregistry" 300s

log_step "3.2 — arctl auth"
if command -v arctl >/dev/null 2>&1; then
  arctl whoami 2>/dev/null || log_warn "arctl not authenticated — run: arctl login"
else
  log_warn "arctl not installed — install from Solo before continuing"
fi

log_step "3.3 — cosign signing policy"
kubectl_apply "$MANIFESTS_DIR/phase03-registry/policy-require-signing.yaml"

log_step "3.4 — digest fingerprinting policy"
kubectl_apply "$MANIFESTS_DIR/phase03-registry/policy-digest-fingerprint.yaml"

log_step "3.5 — generate cosign keys + sign images"
mkdir -p "$COSIGN_KEY_DIR"
if [[ ! -f "$COSIGN_ORG_KEY" ]]; then
  ( cd "$COSIGN_KEY_DIR" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix org )
fi
if [[ ! -f "$COSIGN_UNTRUSTED_KEY" ]]; then
  ( cd "$COSIGN_KEY_DIR" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix untrusted )
fi

# Sign first 3 with org key, evil-tools with untrusted key
for img in "$IMG_ACCOUNT_MCP" "$IMG_TRANSACTION_MCP" "$IMG_TICKET_MCP"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    COSIGN_PASSWORD="" cosign sign --key "$COSIGN_ORG_KEY" --yes "$img" || log_warn "sign $img failed"
  else
    log_warn "$img not built yet — Phase 5 will build it"
  fi
done
if docker image inspect "$IMG_EVIL_CLEAN" >/dev/null 2>&1; then
  COSIGN_PASSWORD="" cosign sign --key "$COSIGN_UNTRUSTED_KEY" --yes "$IMG_EVIL_CLEAN" || log_warn "sign evil-tools failed"
fi

log_step "3.6-3.10 — register artefacts"
register_artefact() {
  local name="$1" version="$2" image="$3" extra="${4:-}"
  if command -v arctl >/dev/null 2>&1; then
    if arctl artifact list 2>/dev/null | grep -q "^${name}.*${version}"; then
      log_ok "${name}:${version} already registered"
      return
    fi
    log "registering ${name}:${version}"
    # shellcheck disable=SC2086
    arctl artifact register --name "$name" --version "$version" --image "$image" $extra || log_warn "register $name failed"
  else
    log_warn "arctl missing — skipping ${name}:${version}"
  fi
}

register_artefact account-mcp     1.0.0 "$IMG_ACCOUNT_MCP"
register_artefact transaction-mcp 1.0.0 "$IMG_TRANSACTION_MCP"
register_artefact ticket-mcp      1.0.0 "$IMG_TICKET_MCP"

# evil-tools: should fail signature check
log "evil-tools registration (expect rejection)"
register_artefact evil-tools 1.0.0 "$IMG_EVIL_CLEAN" || true

# Force-register evil-tools (Phase 3.10 — the demo gotcha)
log "evil-tools force-register --allow-unsigned (the demo gotcha)"
register_artefact evil-tools 1.0.0 "$IMG_EVIL_CLEAN" "--allow-unsigned"

log_step "3.11 — evidence (DORA Art. 28 — sub-outsourcing register)"
P3=$(evidence_dir 3)
if command -v arctl >/dev/null 2>&1; then
  arctl artifact list --format json > "$P3/sub-outsourcing-register.json" 2>/dev/null || true
fi

log_ok "Phase 3 (agentregistry) complete"
