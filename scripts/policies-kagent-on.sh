#!/usr/bin/env bash
# Apply kagent Enterprise AccessPolicy CRs to the bank cluster.
#
# This is a SEPARATE defence layer from scripts/policies-on.sh:
#
#   policies-on.sh         — Istio AmbientmTLS AuthorizationPolicy (L4
#                            mesh-level deny/allow by SPIFFE principal).
#                            Defends the wire.
#
#   policies-kagent-on.sh  — kagent-enterprise AccessPolicy (this script).
#                            Programs the Istio waypoint with OIDC- and
#                            agent-identity-aware rules at the agent's
#                            front door. Defends the agent invocation
#                            itself: which identities are allowed to
#                            invoke this agent at all.
#
# Both layers can be on at the same time — they protect different things.
# The story for the rug-pull demo: three independent kill-switches
# (cosign / agentgateway / kagent AccessPolicy) and an admin can flip
# any one of them on to defeat the same attack from a different angle.
#
# AccessPolicy requires:
#   1. Enterprise kagent installed on the cluster (provides the CRDs
#      and the translator that pushes rules to the waypoint).
#   2. Each target Agent CR labelled kagent.solo.io/waypoint=true.
#      Without it the translator refuses to program the waypoint.
#   3. A waypoint Gateway in the target namespace (created by the
#      ambient install).
#
# Run scripts/policies-kagent-off.sh to revert.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/topology.sh"
trap on_error ERR

CTX="$(cluster_context "$BANK_CLUSTER")"
NS="$NS_BANK_AGENTS"

log_step "kagent AccessPolicy: turning ON (bank cluster, $NS)"

# Sanity check: the AccessPolicy CRD only exists when Enterprise kagent
# is installed. OSS kagent doesn't ship it.
if ! kubectl --context="$CTX" get crd accesspolicies.policy.kagent-enterprise.solo.io >/dev/null 2>&1; then
  die "AccessPolicy CRD not found — install Enterprise kagent first (scripts/07-kagent.sh)"
fi

log "1/2 — labelling target Agent CRs with kagent.solo.io/waypoint=true"
# The translator needs this label on the Agent itself to know which
# Agents it owns. The label is baked into the Agent manifests in
# manifests/phase06-kagent/agent-*.yaml — this step is idempotent and
# only matters if someone applies the policy against an older Agent.
for ag in support-bot fraud-bot triage-bot; do
  kubectl --context="$CTX" -n "$NS" label agent "$ag" kagent.solo.io/waypoint=true --overwrite 2>&1 | sed 's/^/    /'
done

log "2/3 — applying AccessPolicy CRs"
kubectl --context="$CTX" apply -f "$MANIFESTS_DIR/phase06-kagent-accesspolicy/" 2>&1 | sed 's/^/    /'

# Wait for kagent-controller to translate each AccessPolicy into an
# EnterpriseAgentgatewayPolicy. The translation runs asynchronously and
# typically completes within ~5s.
sleep 5

log "3/3 — patching auto-generated EnterpriseAgentgatewayPolicies"
# Known issue in kagent-enterprise 0.4.0: the AccessPolicy translator
# generates an EnterpriseAgentgatewayPolicy with targetRefs pointing at
# the agent's HTTPRoute. The enterprise-agentgateway controller cannot
# attach such policies (status: ATTACHED=False, message: "HTTPRoute is
# not attached to any Gateway"), because the HTTPRoute's parentRef is
# the agent's Service (Istio Ambient pattern), not a Gateway.
#
# Workaround: rewrite each EAG policy's targetRef to point at the
# matching per-agent waypoint Gateway directly. The policy then attaches
# correctly and the waypoint enforces it.
#
# Once kagent-enterprise upstream ships a fix, this loop becomes a no-op.
for ag in support-bot fraud-bot triage-bot; do
  policy="accesspolicy-${ag}-callers-allowlist-waypoint"
  gateway="agent-${ag}-waypoint"
  # Skip if the policy doesn't exist (its AccessPolicy may not have been
  # applied — e.g. if only one of the agents has a policy).
  if ! kubectl --context="$CTX" -n "$NS" get enterpriseagentgatewaypolicies "$policy" >/dev/null 2>&1; then
    continue
  fi
  log "    retargeting $policy -> Gateway/$gateway"
  kubectl --context="$CTX" -n "$NS" get enterpriseagentgatewaypolicies "$policy" -o json | \
    python3 -c "
import json, sys
d = json.load(sys.stdin)
d['spec']['targetRefs'] = [{
  'group': 'gateway.networking.k8s.io',
  'kind': 'Gateway',
  'name': '$gateway'
}]
print(json.dumps(d))
" | kubectl --context="$CTX" apply -f - >/dev/null 2>&1
done

log "    waiting 10s for the EAG controller to spawn per-agent waypoint Deployments"
sleep 10

# ---------- Operator-install waypoint patches ----------
#
# The enterprise-agentgateway waypoint pods need CLUSTER_ID set explicitly
# when installed via gloo-operator. Without it, the agentgateway binary
# defaults to ClusterID="Kubernetes" in its gRPC metadata, but istiod-gloo
# is configured with CLUSTER_ID="$cluster" — the KubeJWTAuthenticator
# rejects the mismatch ("client claims to be in cluster 'Kubernetes', but
# we only know about local cluster '<cluster>'").
#
# Patch every per-agent waypoint Deployment we just programmed. Skip
# silently for any agent without a deployment yet — the script is
# idempotent and the operator will retry.
CLUSTER_ID="$BANK_CLUSTER"
log "patching waypoint Deployments to set CLUSTER_ID=$CLUSTER_ID"
for ag in support-bot fraud-bot triage-bot; do
  dep="agent-${ag}-waypoint"
  if ! kubectl --context="$CTX" -n "$NS" get deploy "$dep" >/dev/null 2>&1; then
    continue
  fi
  # Idempotent: only add CLUSTER_ID if missing.
  already=$(kubectl --context="$CTX" -n "$NS" get deploy "$dep" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CLUSTER_ID")].value}' 2>/dev/null)
  if [[ "$already" == "$CLUSTER_ID" ]]; then
    log_ok "    $dep already has CLUSTER_ID=$CLUSTER_ID"
    continue
  fi
  kubectl --context="$CTX" -n "$NS" patch deploy "$dep" --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"CLUSTER_ID\",\"value\":\"$CLUSTER_ID\"}}]" \
    2>&1 | sed 's/^/    /'
done
log "    waiting for waypoint pods to roll out with new env"
for ag in support-bot fraud-bot triage-bot; do
  dep="agent-${ag}-waypoint"
  kubectl --context="$CTX" -n "$NS" rollout status deploy/"$dep" --timeout=60s 2>&1 | sed 's/^/    /' || true
done

sleep 3
log_step "Verifying translation status"
# Each AccessPolicy reports state = Applied | Failed in .status.state.
# Failed usually means a referenced subject/target doesn't exist yet or
# the waypoint label is missing.
kubectl --context="$CTX" -n "$NS" get accesspolicy \
  -o jsonpath='{range .items[*]}    {.metadata.name}{": "}{.status.state}{"\n"}{end}'
echo
log "EnterpriseAgentgatewayPolicy attachment:"
kubectl --context="$CTX" -n "$NS" get enterpriseagentgatewaypolicies \
  -o jsonpath='{range .items[*]}    {.metadata.name}{": ACCEPTED="}{.status.ancestors[0].conditions[0].status}{" ATTACHED="}{.status.ancestors[0].conditions[1].status}{"\n"}{end}'

echo ""
log_ok "kagent AccessPolicy is now ENFORCING."
log ""
log "What just turned on:"
log "  • support-bot can only be invoked by triage-bot (in-cluster A2A)"
log "  • fraud-bot   can only be invoked by triage-bot (in-cluster A2A)"
log "  • All other callers (chatbot, ad-hoc curl, another agent, leaked"
log "    token) get a 403 at the waypoint BEFORE the agent's LLM runs."
log "  • Each denied invocation is logged as an Istio access-log line"
log "    visible in Loki and Grafana."
log ""
log "Demonstrate it:"
log "  kubectl --context=$CTX -n $NS exec deploy/triage-bot -c agent -- \\"
log "    curl -sS -o /dev/null -w 'HTTP %{http_code}\\n' \\"
log "    http://support-bot.${NS}.svc.cluster.local:8080/.well-known/agent-card.json"
log "  # expected: HTTP 200  (allowed — triage-bot is in the allowlist)"
log ""
log "  kubectl --context=$CTX -n trustusbank-platform exec deploy/kagent-ui -- \\"
log "    curl -sS -o /dev/null -w 'HTTP %{http_code}\\n' \\"
log "    http://support-bot.${NS}.svc.cluster.local:8080/.well-known/agent-card.json"
log "  # expected: HTTP 403  (denied — kagent-ui is NOT in the allowlist)"
log ""
log "Revert with: scripts/policies-kagent-off.sh"
