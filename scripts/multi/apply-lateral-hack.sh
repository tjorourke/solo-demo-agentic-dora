#!/usr/bin/env bash
# Apply the lateral-hack (cross-cluster EndpointSlices via NodePort).
#
# Background — Solo best-practice path vs this workaround:
# The "best-practice" path is Solo Istio east-west HBONE peering: traffic
# from edge to bank's support-bot flows over port 15008 mTLS, the original
# SPIFFE identity is preserved end-to-end, and AccessPolicy at the bank
# waypoint can match the chatbot's ServiceAccount.
#
# The infrastructure for that path IS in place:
#   * Workspace + WorkspaceSettings (federation enabled, hostSuffix=mesh.internal)
#   * Segment (admin.solo.io/v1alpha1) in every istio-system + namespace labels
#   * VirtualDestination for the publishable services
#   * Per-Service solo.io/expose-cross-cluster=true labels
#   * Federation translator generates ServiceEntries with proper SAN (SPIFFE-preserving)
# The remaining gap: the translator generates SEs with `resolution: STATIC`
# and `endpoints: []` (empty). No paired WorkloadEntries. Result: ztunnel
# resolves the federated VIP but has no upstream endpoint — TCP reset.
#
# Until that endpoint-emission gap is resolved (likely a chart-version or
# RootTrustPolicy nudge), this script re-establishes the cross-cluster
# connectivity via the lateral hack: a local stub Service in each consumer
# cluster + a manual EndpointSlice targeting the producer cluster's node
# IP on a NodePort. NodePort kube-proxy DOES SNAT, which means SPIFFE is
# stripped — so AccessPolicy with a ServiceAccount subject won't match a
# cross-cluster caller. AccessPolicy still works perfectly for intra-cluster
# A2A.
#
# Why this script exists: the kind node IPs change every time the clusters
# are rebuilt (docker network address assignment). Hardcoding them in
# manifests/multi/lateral-hack.yaml means a stale apply after `kind delete`.
# This script reads the current IPs and patches the EndpointSlices.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/topology.sh"
trap on_error ERR

[[ "$MODE" == "multi" ]] || die "apply-lateral-hack.sh requires MODE=multi"

# Pick any one of the bank cluster's node IPs (NodePort works on any node).
BANK_IP=$(docker inspect "${BANK_CLUSTER}-control-plane" --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null)
VENDOR_IP=$(docker inspect "${VENDOR_CLUSTER}-control-plane" --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' 2>/dev/null)

[[ -n "$BANK_IP"   ]] || die "could not detect bank node IP"
[[ -n "$VENDOR_IP" ]] || die "could not detect vendor node IP"

log_step "lateral-hack: bank node IP=$BANK_IP, vendor node IP=$VENDOR_IP"

log "1/4 — render lateral-hack.yaml with current IPs"
TMP=$(mktemp)
sed -e "s/172\.22\.0\.8/$BANK_IP/g; /name: currency-converter-xc/,/conditions/{s/$BANK_IP/$VENDOR_IP/}" \
    "$MANIFESTS_DIR/multi/lateral-hack.yaml" > "$TMP"
# Sed above is fragile when the same IP appears in different roles. Simpler:
# always replace any occurrence of the OLD hardcoded BANK_IP (172.22.0.8) with the new BANK_IP,
# and then the currency-converter-xc block needs special handling because it
# points at vendor's IP. Use a python rewrite instead — cleaner.
python3 - "$MANIFESTS_DIR/multi/lateral-hack.yaml" "$TMP" "$BANK_IP" "$VENDOR_IP" <<'PY'
import sys, re
src, dst, bank_ip, vendor_ip = sys.argv[1:5]
with open(src) as f:
    content = f.read()
# The lateral-hack.yaml has two ip-bearing sections:
#   edge-side stubs (fraud/triage/support/agentgw) → bank node IP
#   bank-side stub (currency-converter) → vendor node IP
# The original hardcodes "172.22.0.8" for the bank IP and "172.22.0.7" for vendor.
# Replace literal hardcoded strings; let helpful comments stay.
content = content.replace('172.22.0.8', bank_ip)
content = content.replace('172.22.0.7', vendor_ip)
with open(dst, 'w') as f:
    f.write(content)
PY

log "2/4 — apply to edge (cross-cluster stubs for bank agents + agentgw)"
kubectl --context="$(cluster_context "$EDGE_CLUSTER")" apply -f "$TMP" 2>&1 | sed 's/^/    /'

# The bank-side bit of lateral-hack.yaml (currency-converter stub) also gets applied
# from the same file via the edge context — but it lives in trustusbank-bank-vendors
# namespace which exists on edge too (from the namespaces phase). That's harmless
# but technically the stub should be on bank's view of vendor. Re-apply on bank:
log "3/4 — apply to bank (cross-cluster stub for vendor's currency-converter)"
# Extract only the currency-converter related resources from the rendered file.
python3 - "$TMP" <<'PY' > /tmp/lh-bank.yaml
import sys, yaml
with open(sys.argv[1]) as f:
    docs = list(yaml.safe_load_all(f))
bank_docs = []
for d in docs:
    if not d: continue
    md = d.get('metadata', {})
    if d.get('kind') == 'Namespace' and md.get('name') == 'trustusbank-bank-vendors':
        bank_docs.append(d)
    elif md.get('name', '').startswith('currency-converter'):
        bank_docs.append(d)
print(yaml.dump_all(bank_docs))
PY
kubectl --context="$(cluster_context "$BANK_CLUSTER")" apply -f /tmp/lh-bank.yaml 2>&1 | sed 's/^/    /'

log "4/4 — verify endpoints point at the right node IPs"
echo "    edge → bank stubs:"
kubectl --context="$(cluster_context "$EDGE_CLUSTER")" -n "$NS_BANK_AGENTS" get endpointslice -o jsonpath='{range .items[*]}    {.metadata.name}: {.endpoints[0].addresses[0]}{"\n"}{end}' 2>/dev/null
echo "    edge → bank platform stub:"
kubectl --context="$(cluster_context "$EDGE_CLUSTER")" -n "$NS_PLATFORM" get endpointslice -o jsonpath='{range .items[*]}    {.metadata.name}: {.endpoints[0].addresses[0]}{"\n"}{end}' 2>/dev/null
echo "    bank → vendor stub:"
kubectl --context="$(cluster_context "$BANK_CLUSTER")" -n "$NS_BANK_VENDORS" get endpointslice -o jsonpath='{range .items[*]}    {.metadata.name}: {.endpoints[0].addresses[0]}{"\n"}{end}' 2>/dev/null

rm -f "$TMP" /tmp/lh-bank.yaml
log_ok "lateral-hack applied with current node IPs"
