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
source "$SCRIPT_DIR/lib/topology.sh"
trap on_error ERR

# Topology-aware: in multi mode the agentregistry lives on the bank
# cluster; in single mode it's the one cluster. Either way we need the
# right --context for kubectl port-forward.
AREG_CLUSTER="$(first_cluster_for_ns "$NS_PLATFORM" || echo "")"
[[ -n "$AREG_CLUSTER" ]] || die "no cluster has namespace $NS_PLATFORM yet"
AREG_CTX="$(cluster_context "$AREG_CLUSTER")"
log "agentregistry target: $AREG_CLUSTER ($AREG_CTX)"

# Note: this phase does NOT use cosign. agentregistry v0.3.x does not yet
# verify cosign signatures at registration (their own governance docs list
# image signing as a planned-but-unshipped gap). When that ships, this is
# where you'd add `cosign sign --key <org-key> <image>` and configure the
# registry's signature enforcement policy.

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
    --kube-context="$AREG_CTX" \
    -n "$NS_PLATFORM" --create-namespace \
    --set "config.jwtPrivateKey=$AREG_JWT_HEX" \
    --set "database.postgres.bundled.image.repository=pgvector" \
    --set "database.postgres.bundled.image.name=pgvector" \
    --set "database.postgres.bundled.image.tag=pg17" \
    --set "database.postgres.vectorEnabled=true" \
    --set "service.type=ClusterIP" \
    || log_warn "agentregistry helm install failed — continuing"
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

log_step "3.3 — image signing (deferred — agentregistry doesn't yet verify)"
# We deliberately do NOT run `cosign sign` here. agentregistry v0.3.x does
# not consume signatures at registration time (per their own CNCF
# self-assessment, image signing is a roadmap gap). Signing images that
# nothing verifies is misleading theatre. When upstream ships verification,
# add a `cosign sign --key <org-key>` call here and configure the registry's
# signing policy to enforce it.

log_step "3.5 — publish MCP artefacts to agentregistry via arctl"
# Port-forward to the registry temporarily so arctl can reach it.
( kubectl --context="$AREG_CTX" -n "$NS_PLATFORM" port-forward svc/agentregistry "$PF_AGENTREGISTRY_PORT:12121" >/dev/null 2>&1 ) &
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

  # The acme-fx vendor entry — published on day 1 with the BENIGN image.
  # In the demo's narrative, this is what the bank's platform team did
  # six months ago when they onboarded acme-fx as a third-party currency
  # converter vendor. The catalogue entry is then untouched for the
  # entire lifetime of the relationship — what changes during the
  # supply-chain attack is the IMAGE that lives behind this tag, not
  # the catalogue record. Realism check: this matches Codecov / 3CX /
  # xz-utils — attacker compromises the vendor's CI, pushes a mutated
  # image at the same tag, the consumer's manifests + catalogue records
  # all stay identical.
  arctl mcp publish "acme-fx/currency-converter" --version 1.0.0 --type oci \
    --package-id "localhost:5001/trustusbank/currency-converter:1.0.0" \
    --transport streamable-http \
    --description "ISO 4217 currency converter from acme-fx.io (third-party vendor)" \
    --overwrite 2>&1 | tee -a "$(evidence_dir 3)/arctl-publish.log" | tail -3 || true
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

log_ok "Phase 3 (agentregistry) complete"
