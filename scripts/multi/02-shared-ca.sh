#!/usr/bin/env bash
# Phase M02 — shared root CA + per-cluster intermediates + cacerts secrets.
#
# All three clusters need to share a trust root so SPIFFE identities issued
# by each istiod can be verified across cluster boundaries. Standard Istio
# multi-cluster pattern: one self-signed root CA, one intermediate CA per
# cluster signed by the root, each cluster gets a cacerts secret in
# istio-system before istiod is installed.
#
# Trust domain is `cluster.local` on EVERY cluster. The Solo Enterprise for
# Istio peering binary and the enterprise-agentgateway waypoint hardcode
# `cluster.local` (no chart knob to override), so the intermediate SAN must
# match. Multi-cluster identity is still unique per cluster via clusterID +
# the per-cluster intermediate signing key. See CLAUDE.md gap notes.
#
# Output is in .certs/ at the repo root (gitignored). Re-running this is
# idempotent — existing certs are kept and re-applied to clusters.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "02-shared-ca.sh requires MODE=multi"

CERTS_DIR="$REPO_ROOT/.certs"
mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

# 1. Root CA — one for all three clusters.
if [[ -f root-cert.pem && -f root-key.pem ]]; then
  log_ok "root CA already exists in .certs/"
else
  log_step "generating root CA"
  openssl req -newkey rsa:4096 -nodes -keyout root-key.pem \
    -x509 -days 36500 -out root-cert.pem \
    -subj "/O=Istio/CN=Root CA" 2>/dev/null
fi

# All clusters share trust domain `cluster.local`. The directory under .certs/
# is a per-cluster label so the keys/certs land in separate dirs, but the
# SPIFFE SAN on the intermediate is always cluster.local.
trust_domain_san() { echo "cluster.local"; }

declare_dir_label() {
  case "$1" in
    "$EDGE_CLUSTER")   echo edge   ;;
    "$BANK_CLUSTER")   echo bank   ;;
    "$VENDOR_CLUSTER") echo vendor ;;
    *) die "no dir label for $1" ;;
  esac
}

# 2. Per-cluster intermediate CAs (all SANs are spiffe://cluster.local/...)
for cluster in "${CLUSTERS[@]}"; do
  label="$(declare_dir_label "$cluster")"
  td="$(trust_domain_san)"
  cdir="$CERTS_DIR/$label"
  mkdir -p "$cdir"

  # If the intermediate exists but its SAN is for an old per-cluster trust
  # domain (edge.local / bank.local / vendor.local), regenerate it.
  needs_regen=true
  if [[ -f "$cdir/ca-cert.pem" && -f "$cdir/ca-key.pem" ]]; then
    if openssl x509 -in "$cdir/ca-cert.pem" -noout -ext subjectAltName \
        | grep -q "spiffe://${td}/ns/istio-system/sa/citadel"; then
      needs_regen=false
    else
      log_warn "intermediate CA for $cluster has stale SAN — regenerating"
    fi
  fi

  if [[ "$needs_regen" == "false" ]]; then
    log_ok "intermediate CA for $cluster ($td) already exists"
  else
    log_step "generating intermediate CA for $cluster (SAN spiffe://$td/...)"
    [[ -f "$cdir/ca-key.pem" ]] || openssl genrsa -out "$cdir/ca-key.pem" 4096 2>/dev/null

    openssl req -new -key "$cdir/ca-key.pem" -out "$cdir/ca.csr" \
      -subj "/O=Istio/CN=Intermediate CA $label" 2>/dev/null

    # Cert extensions: it's a CA, plus SPIFFE URI SAN identifying the
    # citadel SA in the cluster's istio-system. All clusters share the
    # same trust domain (cluster.local) — see header comment for why.
    cat > "$cdir/ca-ext.cnf" <<EXT
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectAltName = URI:spiffe://$td/ns/istio-system/sa/citadel
EXT

    openssl x509 -req -days 3650 \
      -in "$cdir/ca.csr" \
      -CA "$CERTS_DIR/root-cert.pem" -CAkey "$CERTS_DIR/root-key.pem" \
      -CAcreateserial \
      -extfile "$cdir/ca-ext.cnf" \
      -out "$cdir/ca-cert.pem" 2>/dev/null

    # cert-chain.pem = intermediate + root, concatenated in that order
    # (Istio reads this to publish the trust bundle).
    cat "$cdir/ca-cert.pem" "$CERTS_DIR/root-cert.pem" > "$cdir/cert-chain.pem"
    cp "$CERTS_DIR/root-cert.pem" "$cdir/root-cert.pem"
  fi
done

# 3. Apply cacerts secret to each cluster's istio-system namespace.
for cluster in "${CLUSTERS[@]}"; do
  label="$(declare_dir_label "$cluster")"
  cdir="$CERTS_DIR/$label"

  log_step "applying cacerts secret to $cluster:istio-system"
  kctx "$cluster" create namespace istio-system --dry-run=client -o yaml \
    | kctx "$cluster" apply -f - >/dev/null

  # Delete-and-recreate so a regenerated intermediate cleanly replaces.
  kctx "$cluster" -n istio-system delete secret cacerts --ignore-not-found >/dev/null
  kctx "$cluster" -n istio-system create secret generic cacerts \
    --from-file="$cdir/ca-cert.pem" \
    --from-file="$cdir/ca-key.pem" \
    --from-file="$cdir/root-cert.pem" \
    --from-file="$cdir/cert-chain.pem" >/dev/null
  log_ok "$cluster: cacerts applied"
done

log_ok "Phase M02 (shared CA + per-cluster intermediates) complete"
log "  trust domain: cluster.local on every cluster (SAN of intermediates is spiffe://cluster.local/...)"
log "  per-cluster identity: differentiated by clusterID + per-cluster signing keys, not by trust domain"
