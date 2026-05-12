#!/usr/bin/env bash
# Fix: Gloo Mesh federation hijacking the local edge kagent stack.
#
# Symptom: chatbot (on edge, ambient) → kagent-ui/kagent-controller
# fails with "connection reset by peer" because ztunnel routes the
# *local-cluster* hostname (kagent-ui.trustusbank-platform.svc.cluster.local)
# via bank's east/west gateway — the federation autogen ServiceEntry
# unions the local hostname into the global federation entry.
#
# Two-step fix on edge:
#   1. Drop solo.io/service-scope=global from trustusbank-platform
#      (edge's kagent stack is local-only — nothing should reach it
#      via federation).
#   2. Delete the existing autogen entries so the bad union is removed.
#      Gloo Mesh's discovery loop will not recreate them now that the
#      namespace is no longer labelled global.
#
# Plus: enable ambient on trustusbank-platform on edge so the kagent
# pods are enrolled in ztunnel (needed for SPIFFE on the local path).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/common.sh"

CTX_E="kind-${EDGE_CLUSTER}"

log_step "Fixing federation hijack on edge"

# 1. ambient on platform ns
kubectl --context="$CTX_E" label ns trustusbank-platform \
  istio.io/dataplane-mode=ambient --overwrite

# 2. drop global scope from platform ns
kubectl --context="$CTX_E" label ns trustusbank-platform \
  solo.io/service-scope- 2>/dev/null || true

# 3. delete the autogen federation entries for the local kagent stack
for n in kagent-controller kagent-kmcp-controller-manager-metrics-service \
         kagent-postgresql kagent-ui; do
  kubectl --context="$CTX_E" -n istio-system delete serviceentry \
    "autogen.global.trustusbank-platform.$n" --ignore-not-found
  kubectl --context="$CTX_E" -n istio-system delete workloadentry \
    "autogen.trustusbank-bank.trustusbank-platform.$n" --ignore-not-found
done

# 4. restart kagent pods so they pick up ztunnel enrolment
kubectl --context="$CTX_E" -n trustusbank-platform \
  rollout restart deploy/kagent-ui deploy/kagent-controller
kubectl --context="$CTX_E" -n trustusbank-platform \
  rollout status deploy/kagent-ui --timeout=90s
kubectl --context="$CTX_E" -n trustusbank-platform \
  rollout status deploy/kagent-controller --timeout=90s

log_ok "federation-hijack fix applied on edge"
