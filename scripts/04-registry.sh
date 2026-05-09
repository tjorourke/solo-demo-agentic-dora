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
# Release asset is named agentregistry-<semver>.tgz (no leading 'v').
# The chart needs:
#   - config.jwtPrivateKey (a hex string, NOT a PEM key — yes, confusing)
#   - bundled postgres MUST have pgvector — override default postgres:18 image
AREG_VERSION="${AREG_VERSION:-0.3.3}"
AREG_CHART_TGZ="/tmp/agentregistry-${AREG_VERSION}.tgz"
if [[ ! -s "$AREG_CHART_TGZ" ]]; then
  log "downloading agentregistry chart v${AREG_VERSION}"
  curl -fsSL -o "$AREG_CHART_TGZ" \
    "https://github.com/agentregistry-dev/agentregistry/releases/download/v${AREG_VERSION}/agentregistry-${AREG_VERSION}.tgz" \
    || log_warn "chart download failed — agentregistry will be skipped"
fi

AREG_JWT_HEX="$(openssl rand -hex 32)"
if [[ -s "$AREG_CHART_TGZ" ]] && file "$AREG_CHART_TGZ" | grep -q gzip; then
  helm upgrade --install agentregistry "$AREG_CHART_TGZ" \
    -n "$NS_PLATFORM" --create-namespace \
    --set "config.jwtPrivateKey=$AREG_JWT_HEX" \
    --set "database.postgres.bundled.image.repository=pgvector" \
    --set "database.postgres.bundled.image.name=pgvector" \
    --set "database.postgres.bundled.image.tag=pg17" \
    --set "database.postgres.vectorEnabled=true" \
    --set "service.type=ClusterIP" \
    || log_warn "agentregistry helm install failed — digest-watcher still provides the rug-pull canary"
else
  log_warn "skipping agentregistry — chart unavailable."
fi
wait_for_pods_ready "$NS_PLATFORM" "app.kubernetes.io/name=agentregistry" 300s 2>/dev/null \
  || log_warn "agentregistry not ready — will continue and try to register"

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

log_step "3.5 — publish MCP artefacts to agentregistry via arctl"
# Port-forward to the registry temporarily so arctl can reach it.
( kubectl -n "$NS_PLATFORM" port-forward svc/agentregistry "$PF_AGENTREGISTRY_PORT:12121" >/dev/null 2>&1 ) &
AREG_PF_PID=$!
sleep 3
export ARCTL_API_BASE_URL="http://localhost:$PF_AGENTREGISTRY_PORT"

if command -v arctl >/dev/null 2>&1; then
  for srv in account-mcp transaction-mcp ticket-mcp; do
    arctl mcp publish "trustusbank/$srv" --version 1.0.0 --type oci \
      --package-id "localhost:5001/trustusbank/$srv:1.0.0" \
      --transport streamable-http \
      --description "TrustUsBank $srv (signed by org key)" \
      --overwrite 2>&1 | tee -a "$(evidence_dir 3)/arctl-publish.log" | tail -3 || true
  done

  # NOTE: evil-tools is INTENTIONALLY NOT registered here. The clean
  # baseline state is "3 legitimate tools in the catalogue". The
  # ./scripts/test-malicious-actor.sh script registers evil-tools as
  # the FIRST step of the attack — that's the realistic narrative
  # ('an operator pulls a third-party tool from a public catalog
  # and force-allows it because they're in a hurry').
else
  log_warn "arctl missing — cannot publish artefacts"
fi
kill "$AREG_PF_PID" 2>/dev/null || true

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
