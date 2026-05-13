#!/usr/bin/env bash
# Multi-cluster prereqs — checks beyond the single-cluster set.
# Adds: gcloud (for soloio-img registry auth), Solo Istio license key,
# helm OCI support (helm 3.8+), enough docker memory.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

log_step "multi-prereqs"

# Reuse the existing single-cluster prereqs first (kind, kubectl, helm, ...).
bash "$SCRIPT_DIR/../00-prereqs.sh"

require_cmd gcloud
require_cmd docker

# Source licenses from secrets/secrets-envs.sh if present. The file is
# gitignored (see secrets/README.md) and exports MESH_LICENSE_KEY,
# AGENTGATEWAY_LICENSE_KEY, KAGENT_LICENSE_KEY, etc.
if [[ -f "$REPO_ROOT/secrets/secrets-envs.sh" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/secrets/secrets-envs.sh"
fi

# The Solo Istio data plane (istiod-gloo) needs an ENTERPRISE license for
# the MultiCluster feature. The "Solo Enterprise for Istio" product is the
# rename of the former "Gloo Mesh" — so the license that unlocks it has
# `product: gloo-mesh`, `lt: ent` in its JWT. A trial license
# (`product: gloo-trial`) is rejected by istiod-gloo and the cross-cluster
# auto-SE/WE generation never fires.
#
# If both are present, prefer the enterprise MESH_LICENSE_KEY.
if [[ -n "${MESH_LICENSE_KEY:-}" ]]; then
  export SOLO_ISTIO_LICENSE_KEY="$MESH_LICENSE_KEY"
fi
[[ -n "${SOLO_ISTIO_LICENSE_KEY:-}" ]] \
  || die "no Solo license available — set MESH_LICENSE_KEY in secrets/secrets-envs.sh (or SOLO_ISTIO_LICENSE_KEY in .env)"

# Quick sanity-check that the license is the right kind. Decode the JWT
# payload and look for trial markers — warn loudly if the trial product
# is selected, because cross-cluster will silently fall back to the
# lateral-hack path.
payload="$(echo "$SOLO_ISTIO_LICENSE_KEY" | awk -F. '{print $2}')"
# pad to multiple of 4 for base64
padded="$payload$(printf '=%.0s' $(seq 1 $((4 - ${#payload} % 4))))"
decoded=$(echo "$padded" | base64 -d 2>/dev/null || echo "")
if echo "$decoded" | grep -q '"product":"gloo-trial"'; then
  log_warn "SOLO_ISTIO_LICENSE_KEY is a TRIAL license — multi-cluster features will be DISABLED."
  log_warn "Drop an enterprise license into secrets/secrets-envs.sh (MESH_LICENSE_KEY=eyJ...) to unlock."
fi

# Helm 3.8+ for OCI chart support
helm_version="$(helm version --short | sed 's/^v//; s/+.*//')"
log "helm version: $helm_version"

# Docker memory sanity — three kind clusters + Istio Ambient are heavy.
mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
if (( mem_gb > 0 && mem_gb < 8 )); then
  log_warn "Docker has ${mem_gb}G RAM — multi-cluster wants 8G+. Adjust in Docker Desktop → Resources."
else
  log "docker memory: ${mem_gb}G"
fi

# Verify gcloud is authed and the soloio-img registry is readable.
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
  die "gcloud not signed in — run: gcloud auth login (use your @solo.io account)"
fi

if ! grep -q '"us-docker.pkg.dev"' "$HOME/.docker/config.json" 2>/dev/null; then
  log_warn "docker not configured for us-docker.pkg.dev — running: gcloud auth configure-docker us-docker.pkg.dev"
  gcloud auth configure-docker us-docker.pkg.dev --quiet
fi

# Sanity-pull one Solo Istio image to fail fast if auth/license is wrong.
log "smoke-testing Solo Istio image pull (pilot:${SOLO_ISTIO_VERSION:-1.29.2-patch0-solo})"
docker pull "us-docker.pkg.dev/soloio-img/istio/pilot:${SOLO_ISTIO_VERSION:-1.29.2-patch0-solo}" >/dev/null \
  || die "cannot pull pilot image — check gcloud auth + @solo.io access"

log_ok "multi-prereqs complete"
