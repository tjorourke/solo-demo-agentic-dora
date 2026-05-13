#!/usr/bin/env bash
# Packages every YAML manifest the demo applies into two downloadable
# bundles — one per topology. Each bundle has a README that explains
# what each file is and the CRDs it touches.
#
# Output:
#   docs/downloads/trustusbank-single-cluster.zip
#   docs/downloads/trustusbank-multi-cluster.zip

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="$REPO_ROOT/docs/downloads"
mkdir -p "$OUT_DIR"

stage() {
  mktemp -d -t "trustusbank-XXXXXX"
}

copy_phase() {
  local stage_dir="$1" src="$2" target="${3:-}"
  if [[ ! -e "$src" ]]; then return 0; fi
  if [[ -z "$target" ]]; then target="$src"; fi
  mkdir -p "$stage_dir/$(dirname "$target")"
  cp -R "$src" "$stage_dir/$target"
}

phase_description() {
  case "$1" in
    phase01-ambient)    echo "Istio Ambient mesh setup: ztunnel default-deny + waypoint enrolment + initial AuthorizationPolicy."  ;;
    phase01-attacker)   echo "The mock-attacker pod (C2 sink) + the egress-block AuthorizationPolicy that defeats it." ;;
    phase02-observability) echo "Prometheus + Loki + Tempo + Grafana + Alertmanager + MailHog (SOC inbox) + OTel + the PrometheusRules that fire DORA alerts." ;;
    phase03-registry)   echo "Agentregistry — Solo's container/MCP package registry, for signing-aware MCP image publication." ;;
    phase04-mcp-servers) echo "The three internal MCP servers (account / transaction / ticket) + the vendor's currency-converter." ;;
    phase05-agentgateway) echo "agentgateway data plane + the AgentgatewayBackend/Policy CRs that gate every MCP tool call." ;;
    phase06-kagent)     echo "Solo Enterprise for kagent: Agent CRs (support-bot / fraud-bot / triage-bot), ModelConfig, RemoteMCPServers." ;;
    phase06-kagent-accesspolicy) echo "Defence layer 3: AccessPolicy CRs that whitelist which identities may invoke each Agent at the per-agent waypoint." ;;
    phase07-a2a)        echo "Cross-namespace AuthorizationPolicies for agent-to-agent traffic." ;;
    phase08-bad-actor)  echo "Demo helpers for the rug-pull act." ;;
    phase09-frontend)   echo "The customer-facing chatbot (nginx + SPA) — A2A JSON-RPC client against support-bot." ;;
    multi)              echo "Multi-cluster glue: the lateral-hack EndpointSlices that point cross-cluster service stubs at remote NodePorts." ;;
    dex)                echo "dex OIDC IdP helm values — single static user, in-memory storage." ;;
    oauth2-proxy)       echo "oauth2-proxy helm values template — front-door that intercepts /oauth2/* on the kagent UI." ;;
    kagent-enterprise)  echo "Slim helm values for the kagent-enterprise chart (OIDC + RBAC + resource pruning)." ;;
    *)                  echo "(no description)" ;;
  esac
}

file_description() {
  local phase="$1" basename="$2"
  case "$phase/$basename" in
    phase01-ambient/deny-all-cross-ns.yaml)        echo "default-deny AuthorizationPolicy applied to the bank-* namespaces" ;;
    phase01-ambient/allow-agents-to-mcp.yaml)      echo "ALLOW rule: kagent SAs may call MCP servers" ;;
    phase01-attacker/mock-attacker.yaml)           echo "the C2 sink Deployment + Service (in external-attacker ns, deliberately not ambient)" ;;
    phase01-attacker/deny-egress-to-attacker.yaml) echo "the single deny rule that defeats the rug-pull at L4 (bank-* -> external-attacker)" ;;
    phase02-observability/authz-deny-alert.yaml)   echo "PodMonitor on ztunnel + PrometheusRule that fires IstioAuthZDeny + BankToAttackerAttempt" ;;
    phase02-observability/kagent-accesspolicy-deny-alert.yaml) echo "PodMonitor on per-agent waypoints + KagentAccessPolicyDeny rule" ;;
    phase02-observability/alertmanager-email.yaml) echo "AlertmanagerConfig routing the demo's alerts to MailHog over plain SMTP" ;;
    phase02-observability/mailhog.yaml)            echo "the MailHog SMTP catcher (SOC inbox)" ;;
    phase02-observability/istio-telemetry.yaml)    echo "Telemetry CR routing mesh telemetry to the OTel collector" ;;
    phase02-observability/agentgateway-podmonitor.yaml) echo "PodMonitor on agentgateway pods" ;;
    phase04-mcp-servers/account-mcp.yaml)          echo "account-mcp Deployment + Service" ;;
    phase04-mcp-servers/transaction-mcp.yaml)      echo "transaction-mcp Deployment + Service" ;;
    phase04-mcp-servers/ticket-mcp.yaml)           echo "ticket-mcp Deployment + Service" ;;
    phase04-mcp-servers/currency-converter.yaml)   echo "the vendor MCP server — gets swapped to the rug-pull image during the attack" ;;
    phase06-kagent/agent-support-bot.yaml)         echo "support-bot Agent CR — customer-facing, calls all 3 internal MCPs + currency-converter" ;;
    phase06-kagent/agent-fraud-bot.yaml)           echo "fraud-bot Agent CR — risk analysis from transactions" ;;
    phase06-kagent/agent-triage-bot.yaml)          echo "triage-bot Agent CR — escalation/ticket flow" ;;
    phase06-kagent/modelconfig.yaml)               echo "ModelConfig (anthropic-haiku)" ;;
    phase06-kagent/remote-mcp-servers.yaml)        echo "the 4 RemoteMCPServer entries (account / transaction / ticket / currency-converter)" ;;
    phase06-kagent/telemetry.yaml)                 echo "agent-side Telemetry config -> OTel" ;;
    phase06-kagent-accesspolicy/accesspolicy-support-bot-currency.yaml) echo "AccessPolicy CRs for support-bot + fraud-bot (defence layer 3)" ;;
    phase07-a2a/tenant-isolation.yaml)             echo "cross-namespace A2A AuthorizationPolicies" ;;
    phase09-frontend/chatbot.yaml)                 echo "the chatbot Deployment + Service (nginx + SPA, A2A JSON-RPC client)" ;;
    multi/lateral-hack.yaml)                       echo "manual EndpointSlices that wire cross-cluster service stubs to remote NodePorts (lateral hack)" ;;
    dex/values.yaml)                               echo "dex IdP helm values — single static user, in-memory storage" ;;
    oauth2-proxy/values.template.yaml)             echo "oauth2-proxy helm values template — substituted with secrets at install time" ;;
    kagent-enterprise/values-slim.yaml)            echo "kagent-enterprise helm values — slim profile (OIDC + RBAC + resource pruning)" ;;
    *)                                             echo "(see file)" ;;
  esac
}

write_readme() {
  local stage_dir="$1" topology="$2"
  {
    echo "# TrustUsBank — DORA agentic demo (${topology}-cluster bundle)"
    echo
    echo "Every Kubernetes manifest the demo applies, grouped by install phase."
    echo "Apply order matches the script numbering: 01 -> 02 -> 03 -> 04 -> 05 -> 06 -> 06-accesspolicy -> 07 -> 09."
    echo
    echo "Companion install scripts live at https://github.com/tjorourke/solo-demo-agentic-dora."
    echo "This bundle is the manifest dump for offline review and audit."
    echo
    echo "## Quick start"
    echo
    echo '```bash'
    echo "# from the bundle root"
    echo "kubectl apply -f phase01-ambient/"
    echo "kubectl apply -f phase02-observability/"
    echo "# ... in order"
    echo '```'
    echo
    echo "For end-to-end install with build/load/registry orchestration, use the repo's install scripts. This bundle is for **reading and auditing** what the demo applies."
    echo
    echo "## Phases (apply in order)"
    echo
    local phase
    for phase in $(cd "$stage_dir" && ls -d phase* 2>/dev/null | sort); do
      [[ -d "$stage_dir/$phase" ]] || continue
      echo
      echo "### \`$phase/\`"
      echo
      phase_description "$phase"
      echo
      (cd "$stage_dir/$phase" && find . -type f -name '*.yaml' | sort) | while read -r f; do
        f="${f#./}"
        echo "- \`$f\` — $(file_description "$phase" "$(basename "$f")")"
      done
    done
    # Helm value bundles too
    for d in multi dex oauth2-proxy kagent-enterprise; do
      [[ -d "$stage_dir/$d" ]] || continue
      echo
      echo "### \`$d/\`"
      echo
      phase_description "$d"
      echo
      (cd "$stage_dir/$d" && find . -type f | sort) | while read -r f; do
        f="${f#./}"
        echo "- \`$f\` — $(file_description "$d" "$(basename "$f")")"
      done
    done

    cat <<'APPENDIX'

---

## CRD reference (every kind in this bundle)

| Kind | API group | Role in the demo |
|---|---|---|
| `Namespace` | core | Tenancy boundary. Several are labelled `istio.io/dataplane-mode=ambient` so workloads are enrolled in ztunnel. |
| `ServiceAccount` | core | Identity. SPIFFE prefix `cluster.local/ns/<ns>/sa/<sa>` is built from this. |
| `Service` / `Deployment` | core / apps | Standard workload primitives. |
| `EndpointSlice` | discovery.k8s.io | Used by `multi/lateral-hack.yaml` to plant cross-cluster endpoints pointing at NodePorts. |
| `ConfigMap` | core | Holds rendered configs (e.g. kagent-ui nginx, OTel pipeline). |
| `Gateway` / `HTTPRoute` | gateway.networking.k8s.io | Per-agent waypoint Gateways + routes. Also east/west GWs (multi-cluster). |
| `AuthorizationPolicy` | security.istio.io | ALLOW/DENY at L4 by SPIFFE identity or by source namespace. Applied by `scripts/policies-on.sh`. |
| `Telemetry` | telemetry.istio.io | Routes mesh telemetry to the OTel collector. |
| `Agent` | kagent.dev/v1alpha2 | Declarative agent (system prompt + tools list). kagent generates a Deployment + Service per Agent. |
| `ModelConfig` | kagent.dev/v1alpha2 | LLM provider + model + API key reference. |
| `RemoteMCPServer` | kagent.dev/v1alpha2 | External MCP server URL + tool list. Resolved by an Agent's tool list. |
| `MCPServer` | kagent.dev | In-cluster MCP server (kagent runs the pod itself; alternative to RemoteMCPServer). |
| `AccessPolicy` | policy.kagent-enterprise.solo.io | **Enterprise-only.** Declares who may invoke an Agent (UserGroup / ServiceAccount / Agent subject). |
| `EnterpriseAgentgatewayPolicy` | enterpriseagentgateway.solo.io | Auto-generated from AccessPolicy. Targets a per-agent waypoint Gateway. CEL on `source.identity.*`. |
| `AgentgatewayBackend` | agentgateway.dev | Declares an MCP upstream (one per MCP server). |
| `AgentgatewayPolicy` | agentgateway.dev | L7 policy attached to a Gateway/HTTPRoute. CEL on `mcp.method`, `mcp.tool.name`, `source.identity`. |
| `PodMonitor` / `PrometheusRule` / `AlertmanagerConfig` | monitoring.coreos.com | Observability. `KagentAccessPolicyDeny` fires on waypoint 403s, routes to MailHog. |
| `ServiceMeshController` | operator.gloo.solo.io | **Multi-cluster bundle.** Gloo Operator's declarative mesh-install CR (one per cluster). Replaces 4 helm charts. |
| `Workspace` / `WorkspaceSettings` / `KubernetesCluster` | admin.gloo.solo.io | **Multi-cluster bundle.** Solo management-plane primitives. |

---

## Three-layer defence

This bundle has all three rug-pull defence layers:

1. **Image signing (admission)** — cosign signatures on every MCP image; admission controller rejects unsigned. (`phase03-registry/` shows the publisher path; only present in the multi-cluster bundle.)
2. **agentgateway policy (gateway)** — `AgentgatewayPolicy` on the agentgateway's HTTPRoutes restricts which MCP tools each Agent may invoke. (`phase05-agentgateway/`)
3. **kagent AccessPolicy (agent runtime)** — `AccessPolicy` on each Agent at the per-agent waypoint denies callers the policy doesn't list. (`phase06-kagent-accesspolicy/`)

Run any combination of `scripts/policies-on.sh` and `scripts/policies-kagent-on.sh` to demonstrate layer 2 and 3 independently.
APPENDIX
  } > "$stage_dir/README.md"
}

# Build SINGLE-CLUSTER bundle
echo "==> staging single-cluster bundle"
SINGLE=$(stage)
for d in phase01-ambient phase01-attacker phase02-observability phase04-mcp-servers \
         phase05-agentgateway phase06-kagent phase06-kagent-accesspolicy \
         phase07-a2a phase09-frontend dex oauth2-proxy kagent-enterprise; do
  copy_phase "$SINGLE" "manifests/$d" "$d"
done
write_readme "$SINGLE" single
(cd "$SINGLE" && zip -qr "$OUT_DIR/trustusbank-single-cluster.zip" . -x "*.DS_Store")
cd "$REPO_ROOT"
rm -rf "$SINGLE"
SIZE=$(du -h "$OUT_DIR/trustusbank-single-cluster.zip" | cut -f1)
echo "    wrote $OUT_DIR/trustusbank-single-cluster.zip ($SIZE)"

# Build MULTI-CLUSTER bundle (single + multi-only)
echo "==> staging multi-cluster bundle"
MULTI=$(stage)
for d in phase01-ambient phase01-attacker phase02-observability phase03-registry \
         phase04-mcp-servers phase05-agentgateway phase06-kagent \
         phase06-kagent-accesspolicy phase07-a2a phase09-frontend \
         multi dex oauth2-proxy kagent-enterprise; do
  copy_phase "$MULTI" "manifests/$d" "$d"
done
write_readme "$MULTI" multi
(cd "$MULTI" && zip -qr "$OUT_DIR/trustusbank-multi-cluster.zip" . -x "*.DS_Store")
cd "$REPO_ROOT"
rm -rf "$MULTI"
SIZE=$(du -h "$OUT_DIR/trustusbank-multi-cluster.zip" | cut -f1)
echo "    wrote $OUT_DIR/trustusbank-multi-cluster.zip ($SIZE)"

echo ""
echo "Bundles ready in $OUT_DIR/."
