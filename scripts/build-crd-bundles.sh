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

# Build MULTI-CLUSTER bundle — RAW MANIFESTS, organised BY CLUSTER folder.
# Pulls live CRs from each cluster (Gateway / SMC / Workspace / remote-secret
# templates) AND copies the static manifests in the right cluster folder
# based on where the install scripts apply them. No install scripts in the
# bundle — manifests only.
echo "==> staging multi-cluster bundle (by-cluster layout)"

# Required: connected kind contexts for snapshotting live state.
CTXS="$(kubectl config get-contexts -o name 2>/dev/null || true)"
LIVE_MODE=1
for c in trustusbank-edge trustusbank-bank trustusbank-vendor; do
  case $'\n'"$CTXS"$'\n' in
    *$'\n'"kind-$c"$'\n'*) : ;;
    *) LIVE_MODE=0 ;;
  esac
done
if [[ "$LIVE_MODE" -eq 0 ]]; then
  echo "    (no live multi-cluster contexts found — emitting static-only bundle)"
fi

MULTI=$(stage)

# ---------- shared/ ----------
SHARED="$MULTI/shared"
mkdir -p "$SHARED"
cat > "$SHARED/README.md" <<'SHARED_README'
# `shared/` — applied to all three clusters

Files in this folder apply to **every cluster** in the multi-cluster
install (trustusbank-edge, trustusbank-bank, trustusbank-vendor).

| File | Purpose |
|---|---|
| `00-namespaces-and-labels.yaml` | Workload namespaces with `istio.io/dataplane-mode=ambient` AND `topology.istio.io/network=<cluster>` labels (the network label is what lets istiod classify cross-cluster pods). |
| `01-cacerts-secret.example.yaml` | Template for the `cacerts` Secret in `istio-system` — holds the per-cluster intermediate CA. All three intermediates MUST be signed with SAN `spiffe://cluster.local/...`. |
| `02-solo-istio-license.example.yaml` | Template for the `solo-istio-license` Secret in `istio-system`. Must be an **enterprise** (non-trial) Solo Mesh license — the trial license has `product: gloo-trial` and istiod-gloo rejects it for the MultiCluster feature. |
| `03-servicemeshcontroller.example.yaml` | The `ServiceMeshController` CR per cluster — declares cluster name, network, trust domain (`cluster.local` on every cluster). Gloo Operator reconciles this into the istiod / ztunnel / istio-cni Deployments. |

The CA + license Secrets are templated because their content is
environment-specific. Place real values where the placeholder shows.
SHARED_README

# Namespaces overview YAML (representative)
cat > "$SHARED/00-namespaces-and-labels.yaml" <<'NAMESPACES_YAML'
# Run on EVERY cluster. The set of namespaces that exists per cluster
# differs (chatbot on edge; agents/MCPs/agentgateway on bank;
# currency-converter on vendor) — only create the ones whose workloads
# will be present in this cluster.
#
# The CRITICAL piece is the `topology.istio.io/network` label on EVERY
# workload namespace. Without it, istiod can't tell what network a
# remote pod belongs to and the cross-cluster endpoint rewriting via
# the east-west GW never fires.
---
apiVersion: v1
kind: Namespace
metadata:
  name: trustusbank-bank-agents
  labels:
    istio.io/dataplane-mode: ambient
    topology.istio.io/network: <CLUSTER_NAME>   # e.g. trustusbank-bank
---
apiVersion: v1
kind: Namespace
metadata:
  name: trustusbank-bank-vendors
  labels:
    istio.io/dataplane-mode: ambient
    topology.istio.io/network: <CLUSTER_NAME>
---
apiVersion: v1
kind: Namespace
metadata:
  name: trustusbank-bank-frontend
  labels:
    istio.io/dataplane-mode: ambient
    topology.istio.io/network: <CLUSTER_NAME>
---
apiVersion: v1
kind: Namespace
metadata:
  name: trustusbank-platform
  labels:
    topology.istio.io/network: <CLUSTER_NAME>
---
apiVersion: v1
kind: Namespace
metadata:
  name: trustusbank-observability
  labels:
    topology.istio.io/network: <CLUSTER_NAME>
---
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
  labels:
    topology.istio.io/network: <CLUSTER_NAME>
NAMESPACES_YAML

cat > "$SHARED/01-cacerts-secret.example.yaml" <<'CACERTS_TPL'
# `cacerts` Secret in istio-system — holds the per-cluster intermediate CA
# that istiod uses to sign workload SPIFFE certs.
#
# CRITICAL: the intermediate's URI SAN MUST be
#   spiffe://cluster.local/ns/istio-system/sa/citadel
# (NOT spiffe://<cluster>.local/...). All three clusters share the same
# trust domain `cluster.local`; per-cluster identity is differentiated
# via the per-cluster intermediate signing key + the `clusterID` env on
# istiod. Mismatched SAN = silent cross-cluster cert validation failure.
#
# Generate via scripts/multi/02-shared-ca.sh in the install scripts.
apiVersion: v1
kind: Secret
metadata:
  name: cacerts
  namespace: istio-system
type: Opaque
data:
  ca-cert.pem:    <base64 of intermediate CA cert>
  ca-key.pem:     <base64 of intermediate CA key>
  root-cert.pem:  <base64 of shared root CA cert>
  cert-chain.pem: <base64 of intermediate + root concatenated>
CACERTS_TPL

cat > "$SHARED/02-solo-istio-license.example.yaml" <<'LICENSE_TPL'
# Solo Enterprise for Istio license. The Solo Mesh enterprise license
# (`product: gloo-mesh`, `lt: ent`) unlocks the MultiCluster feature.
#
# A TRIAL license (`product: gloo-trial`, `addOns: []`) will NOT unlock
# MultiCluster — istiod-gloo logs:
#   "license state initialized: UNSET"
#   "SKIPPING FEATURE MultiCluster due to licensing issue"
# and silently runs in single-cluster mode.
#
# This Secret is referenced by the istiod-gloo Deployment via the
# `SOLO_LICENSE_KEY` env (see per-cluster `02-istiod-license-env-patch.yaml`).
apiVersion: v1
kind: Secret
metadata:
  name: solo-istio-license
  namespace: istio-system
type: Opaque
stringData:
  license: <paste-enterprise-license-JWT-here>
LICENSE_TPL

cat > "$SHARED/03-servicemeshcontroller.example.yaml" <<'SMC_TPL'
# ServiceMeshController — Gloo Operator's declarative mesh install.
# One per cluster. Replaces the 4-helm-release path (base/istiod/cni/ztunnel)
# with a single CR.
#
# trustDomain MUST be `cluster.local` (the enterprise-agentgateway waypoint
# binary hardcodes this — no chart knob to override).
# cluster + network differ per cluster — they're the multi-cluster identity.
apiVersion: operator.gloo.solo.io/v1
kind: ServiceMeshController
metadata:
  name: managed-istio
  labels:
    app.kubernetes.io/part-of: trustusbank
spec:
  cluster: <CLUSTER_NAME>          # e.g. trustusbank-bank
  network: <CLUSTER_NAME>
  trustDomain: cluster.local
  version: "1.29.2-patch0"
  dataplaneMode: Ambient
  distribution: Standard
  installNamespace: istio-system
  scalingProfile: Demo              # use Default/Large in production
  trafficCaptureMode: Auto
  onConflict: Force
  image:
    registry: us-docker.pkg.dev
    repository: soloio-img/istio
SMC_TPL

# ---------- per-cluster folders ----------
# Helper: snapshot live CR YAML, cleaned of cluster-set fields.
# Uses kubectl's `-o json` + python (stdlib only) + minimal sanitisation.
# Strips: resourceVersion, uid, creationTimestamp, generation, managedFields,
# ownerReferences, selfLink, status, and the kubectl last-applied annotation.
# Emits YAML via a simple json-to-yaml converter (no PyYAML dependency).
snapshot_yaml() {
  local ctx="$1"
  local kind_ns="$2"
  local name="$3"
  # shellcheck disable=SC2086
  kubectl --context="$ctx" get $kind_ns "$name" -o json 2>/dev/null | \
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not d:
    sys.exit(0)
m = d.get("metadata", {}) or {}
for f in ("resourceVersion","uid","creationTimestamp","generation","managedFields","ownerReferences","selfLink"):
    m.pop(f, None)
ann = m.get("annotations") or {}
ann.pop("kubectl.kubernetes.io/last-applied-configuration", None)
if not ann:
    m.pop("annotations", None)
labels = m.get("labels") or {}
# strip Solo translator-applied labels that wouldnt be on a hand-authored manifest
for k in list(labels.keys()):
    if k.startswith("agent.gloo.solo.io") or k.startswith("context.mesh.gloo.solo.io") \
       or k.startswith("gloo.solo.io/parent_") or k.startswith("reconciler.mesh.gloo.solo.io") \
       or k.startswith("relay.solo.io") or k.startswith("cluster.multicluster.solo.io") \
       or k == "owner.gloo.solo.io/name":
        del labels[k]
if not labels:
    m.pop("labels", None)
d.pop("status", None)
# Pretty-print as YAML using a minimal converter.
def emit(v, indent=0):
    pad = "  " * indent
    if isinstance(v, dict):
        if not v: return "{}"
        out = []
        for k, vv in v.items():
            if isinstance(vv, (dict, list)) and vv:
                out.append(f"{pad}{k}:")
                out.append(emit(vv, indent+1))
            else:
                out.append(f"{pad}{k}: {emit_scalar(vv)}")
        return "\n".join(out)
    if isinstance(v, list):
        if not v: return "[]"
        out = []
        for item in v:
            if isinstance(item, (dict, list)) and item:
                out.append(f"{pad}-")
                out.append(emit(item, indent+1))
            else:
                out.append(f"{pad}- {emit_scalar(item)}")
        return "\n".join(out)
    return emit_scalar(v)

def emit_scalar(v):
    if v is None: return "null"
    if v is True: return "true"
    if v is False: return "false"
    s = str(v)
    if any(c in s for c in [":", "#", "{", "}", "[", "]", "&", "*", "!", "|", ">", "@", "`"]) or s.strip() != s or "\n" in s:
        return json.dumps(s)
    return s

print(emit(d))
' 2>/dev/null || true
}

# Builds a per-cluster folder: peering, remote-secret templates, istiod env patches.
build_cluster_folder() {
  local cluster="$1"
  local cdir="$MULTI/$cluster"
  local ctx="kind-$cluster"
  mkdir -p "$cdir/01-peering" "$cdir/02-remote-secrets"

  # Live snapshots if available.
  if [[ "$LIVE_MODE" -eq 1 ]]; then
    snapshot_yaml "$ctx" "gateway -n istio-eastwest" "istio-eastwest" \
      > "$cdir/01-peering/eastwest-gateway.yaml"
    # peer Gateways for the OTHER two clusters
    for peer in trustusbank-edge trustusbank-bank trustusbank-vendor; do
      [[ "$peer" == "$cluster" ]] && continue
      snapshot_yaml "$ctx" "gateway -n istio-eastwest" "peer-${peer}" \
        > "$cdir/01-peering/peer-${peer}.yaml"
    done
    # istiod-gloo env patch (capture the SOLO_LICENSE_KEY + L7_ENABLED knobs)
    snapshot_yaml "$ctx" "service -n istio-system" "istiod" \
      > "$cdir/00-istiod-alias-service.yaml" 2>/dev/null || true
  else
    # static stub
    cat > "$cdir/01-peering/eastwest-gateway.yaml" <<EWGW
# East-west Gateway for $cluster. Provisions a ztunnel-backed HBONE
# listener on port 15008 and a TLS-passthrough XDS listener on 15012.
# Generated live by the peering helm chart; this template shows the
# expected shape. The Service in front of this Gateway is NodePort in
# the kind setup (peering.solo.io/data-plane-service-type=nodeport).
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: istio-eastwest
  namespace: istio-eastwest
  annotations:
    peering.solo.io/data-plane-service-type: nodeport
  labels:
    istio.io/expose-istiod: "15012"
    topology.istio.io/cluster: $cluster
    topology.istio.io/network: $cluster
spec:
  gatewayClassName: istio-eastwest
  listeners:
    - name: cross-network
      port: 15008
      protocol: HBONE
      tls: { mode: Passthrough }
    - name: xds-tls
      port: 15012
      protocol: TLS
      tls: { mode: Passthrough }
EWGW
  fi

  # remote-secret templates (one per OTHER cluster)
  for peer in trustusbank-edge trustusbank-bank trustusbank-vendor; do
    [[ "$peer" == "$cluster" ]] && continue
    cat > "$cdir/02-remote-secrets/istio-remote-secret-${peer}.example.yaml" <<RSTPL
# Cross-cluster kubeconfig Secret. Tells istiod-gloo on $cluster
# how to read Services/Endpoints/Pods from $peer's Kubernetes API.
# Without this, istiod sees 0 remote clusters and federation silently
# returns 0 endpoints.
#
# Generate via scripts/multi/04b-remote-secrets.sh — it creates the
# token bound to istio-reader-service-account on the producer cluster
# and the CA bundle from kube-root-ca.crt.
apiVersion: v1
kind: Secret
metadata:
  name: istio-remote-secret-${peer}
  namespace: istio-system
  labels:
    istio/multiCluster: "true"
  annotations:
    networking.istio.io/cluster: ${peer}
type: Opaque
stringData:
  ${peer}: |
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        certificate-authority-data: <base64 kube-root-ca.crt from ${peer}>
        server: https://<${peer}-node-ip>:6443
      name: ${peer}
    contexts:
    - context: { cluster: ${peer}, user: ${peer} }
      name: ${peer}
    current-context: ${peer}
    users:
    - name: ${peer}
      user:
        token: <long-lived token for istio-reader-service-account on ${peer}>
RSTPL
  done

  # istiod env patch (license + multi-cluster knobs)
  cat > "$cdir/00-istiod-license-env-patch.yaml" <<ENVPATCH
# kubectl patch applied to the operator-managed istiod-gloo Deployment.
# Adds the env vars Solo Istio's istiod binary needs for MultiCluster +
# its license. Operator's SMC reconciler leaves user-added env alone.
#
# Apply:
#   kubectl -n istio-system patch deploy istiod-gloo --type='strategic' \\
#     --patch-file=00-istiod-license-env-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istiod-gloo
  namespace: istio-system
spec:
  template:
    spec:
      containers:
        - name: discovery
          env:
            - name: SOLO_LICENSE_KEY
              valueFrom:
                secretKeyRef:
                  name: solo-istio-license
                  key: license
            - name: PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES
              value: "false"
ENVPATCH

  cat > "$cdir/00-ztunnel-l7-env-patch.yaml" <<ZTUNPATCH
# Patches the operator-managed ztunnel DaemonSet to enable L7-aware
# HBONE traffic forwarding. Required by Solo's troubleshooting docs
# for Ambient peering.
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ztunnel
  namespace: istio-system
spec:
  template:
    spec:
      containers:
        - name: istio-proxy
          env:
            - name: L7_ENABLED
              value: "true"
ZTUNPATCH

  cat > "$cdir/00-istiod-alias-service.yaml" <<ALIASSVC
# Alias Service: Gloo Operator names istiod 'istiod-gloo' but the
# enterprise-agentgateway waypoint binary hardcodes
#   CA_ADDRESS=istiod.istio-system.svc:15012
# An alias Service called 'istiod' fixes that without touching either
# binary.
apiVersion: v1
kind: Service
metadata:
  name: istiod
  namespace: istio-system
  labels: { app: istiod }
spec:
  selector:
    app: istiod
    istio.io/rev: gloo
  ports:
    - { name: grpc-xds,        port: 15010, protocol: TCP }
    - { name: https-dns,       port: 15012, protocol: TCP }
    - { name: https-webhook,   port: 443,   protocol: TCP }
    - { name: http-monitoring, port: 15014, protocol: TCP }
ALIASSVC
}

# Build a per-cluster README.
cluster_readme() {
  local cluster="$1"
  local role="$2"
  local cdir="$MULTI/$cluster"
  cat > "$cdir/README.md" <<EOF
# \`$cluster/\` — $role

Manifests in this folder are applied to **the \`$cluster\` cluster only**.

Apply order (numeric prefix matches \`shared/\` ordering — \`shared/\`
applies first):

EOF
  (cd "$cdir" && find . -mindepth 1 -maxdepth 1 -type d | sort) | while read -r d; do
    d="${d#./}"
    echo "## \`$d/\`" >> "$cdir/README.md"
    echo >> "$cdir/README.md"
    (cd "$cdir/$d" && find . -maxdepth 1 -type f -name '*.yaml' | sort) | while read -r f; do
      f="${f#./}"
      echo "- \`$f\`" >> "$cdir/README.md"
    done
    echo >> "$cdir/README.md"
  done
}

build_cluster_folder "trustusbank-edge"
build_cluster_folder "trustusbank-bank"
build_cluster_folder "trustusbank-vendor"

# Copy static manifests into the right cluster folder.
# === bank cluster — most workloads live here ===
BANK="$MULTI/trustusbank-bank"
mkdir -p "$BANK/10-platform" "$BANK/11-observability" "$BANK/12-agentgateway" \
         "$BANK/13-mcp-servers" "$BANK/14-agents" "$BANK/15-accesspolicies" \
         "$BANK/16-ambient-policies" "$BANK/17-a2a" "$BANK/20-gloo-mesh"
# Platform: dex + oauth2-proxy + kagent-enterprise + agentregistry
cp manifests/dex/*.yaml                          "$BANK/10-platform/" 2>/dev/null || true
cp manifests/oauth2-proxy/*.yaml                 "$BANK/10-platform/" 2>/dev/null || true
cp manifests/kagent-enterprise/*.yaml            "$BANK/10-platform/" 2>/dev/null || true
[[ -d manifests/phase03-registry ]] && cp -R manifests/phase03-registry/* "$BANK/10-platform/" 2>/dev/null || true
# Observability
cp -R manifests/phase02-observability/* "$BANK/11-observability/" 2>/dev/null || true
# agentgateway
cp -R manifests/phase05-agentgateway/* "$BANK/12-agentgateway/" 2>/dev/null || true
# MCP servers (account, transaction, ticket only — currency-converter is on vendor)
for f in account-mcp.yaml transaction-mcp.yaml ticket-mcp.yaml; do
  [[ -f "manifests/phase04-mcp-servers/$f" ]] && cp "manifests/phase04-mcp-servers/$f" "$BANK/13-mcp-servers/" || true
done
# Agents (all 3 live on bank)
cp -R manifests/phase06-kagent/* "$BANK/14-agents/" 2>/dev/null || true
# AccessPolicies (defence layer 3)
cp -R manifests/phase06-kagent-accesspolicy/* "$BANK/15-accesspolicies/" 2>/dev/null || true
# Ambient policies (default-deny + allow-agents-to-mcp)
cp -R manifests/phase01-ambient/* "$BANK/16-ambient-policies/" 2>/dev/null || true
# A2A tenant isolation
cp -R manifests/phase07-a2a/* "$BANK/17-a2a/" 2>/dev/null || true
# Workspace + WorkspaceSettings — snapshot live if available
if [[ "$LIVE_MODE" -eq 1 ]]; then
  snapshot_yaml "kind-trustusbank-bank" "workspace -n gloo-mesh" "trustusbank" \
    > "$BANK/20-gloo-mesh/workspace.yaml"
  snapshot_yaml "kind-trustusbank-bank" "workspacesettings -n gloo-mesh" "trustusbank" \
    > "$BANK/20-gloo-mesh/workspacesettings.yaml"
fi

# === edge cluster — chatbot only ===
EDGE="$MULTI/trustusbank-edge"
mkdir -p "$EDGE/10-chatbot"
[[ -d manifests/phase09-frontend ]] && cp -R manifests/phase09-frontend/* "$EDGE/10-chatbot/" 2>/dev/null || true

# === vendor cluster — currency-converter + mock-attacker ===
VENDOR="$MULTI/trustusbank-vendor"
mkdir -p "$VENDOR/10-currency-converter" "$VENDOR/11-attacker"
[[ -f manifests/phase04-mcp-servers/currency-converter.yaml ]] && \
  cp manifests/phase04-mcp-servers/currency-converter.yaml "$VENDOR/10-currency-converter/" || true
cp -R manifests/phase01-attacker/* "$VENDOR/11-attacker/" 2>/dev/null || true

# READMEs per cluster
cluster_readme "trustusbank-edge"   "Presentation tier — chatbot frontend only"
cluster_readme "trustusbank-bank"   "Bank tier — agents, MCPs, agentgateway, observability, Solo Mesh mgmt-server"
cluster_readme "trustusbank-vendor" "Vendor tier — currency-converter (rug-pull target) + mock-attacker"

# Top-level README
cat > "$MULTI/README.md" <<TOP_README
# TrustUsBank — multi-cluster bundle (raw manifests, by cluster)

This bundle contains **every Kubernetes manifest** the multi-cluster demo
applies, organised by which cluster receives it. **No install scripts** —
just the YAML.

## Layout

\`\`\`
shared/                # Applied to ALL three clusters (cacerts, license,
                       # ServiceMeshController, namespaces with the
                       # topology.istio.io/network label)
trustusbank-edge/      # Presentation tier — chatbot only
trustusbank-bank/      # Bank tier — agents, MCPs, agentgateway,
                       # observability, Solo Mesh mgmt-server
trustusbank-vendor/    # Vendor tier — currency-converter rug-pull target
                       # + mock-attacker C2 sink
\`\`\`

## Cross-cluster federation primitives

Solo Istio Ambient peering owns federation (NOT Solo Mesh's
\`VirtualDestination\` translator — that fights with peering in this
version and produces ServiceEntries with zero endpoints).

The control plane and data plane both need wiring:

| Layer | Resource | Where |
|---|---|---|
| Data plane: HBONE termination | \`gatewayClassName: istio-eastwest\` Gateway | each cluster's \`01-peering/eastwest-gateway.yaml\` |
| Data plane: remote endpoint refs | \`gatewayClassName: istio-remote\` Gateways | each cluster's \`01-peering/peer-<other>.yaml\` |
| Control plane: remote k8s API access | \`istio-remote-secret-<peer>\` Secrets | each cluster's \`02-remote-secrets/\` |
| istiod license unlock | \`SOLO_LICENSE_KEY\` env on \`istiod-gloo\` | each cluster's \`00-istiod-license-env-patch.yaml\` |
| ztunnel multi-cluster | \`L7_ENABLED=true\` env on \`ztunnel\` | each cluster's \`00-ztunnel-l7-env-patch.yaml\` |
| Network classification | \`topology.istio.io/network=<cluster>\` label on every workload namespace | \`shared/00-namespaces-and-labels.yaml\` |
| Intermediate cert SAN | All intermediates signed with \`spiffe://cluster.local/...\` | \`shared/01-cacerts-secret.example.yaml\` |

Once all the above is in place, every Service in a peered cluster is
reachable from the others as:

- \`<svc>.<ns>.mesh.internal\` — **global** (when the Service has
  \`istio.io/global=true\`)
- \`<svc>.<ns>.svc.cluster.local\` — cluster-local, no cross-cluster

## Apply order

\`\`\`
# On every cluster:
kubectl apply -f shared/

# Then on each cluster (use the right --context):
kubectl --context=kind-trustusbank-edge   apply -R -f trustusbank-edge/
kubectl --context=kind-trustusbank-bank   apply -R -f trustusbank-bank/
kubectl --context=kind-trustusbank-vendor apply -R -f trustusbank-vendor/
\`\`\`

## Three rug-pull defence layers

All three are intact in this bundle:

1. **cosign signature verification** at admission (image-layer defence) —
   \`trustusbank-bank/10-platform/agentregistry/\` shows the publisher path.
2. **agentgateway policy** at the gateway — \`trustusbank-bank/12-agentgateway/\`
   contains \`AgentgatewayPolicy\` CRs that filter MCP tool calls.
3. **kagent AccessPolicy** at the per-agent waypoint — \`trustusbank-bank/15-accesspolicies/\`
   denies disallowed callers. SPIFFE is preserved end-to-end through the
   east-west GW so cross-cluster \`ServiceAccount\` subjects (e.g. the chatbot
   on edge calling support-bot on bank) are enforced.

## CRD reference (every kind in this bundle)

| Kind | API group | Role |
|---|---|---|
| \`ServiceMeshController\` | operator.gloo.solo.io | Declarative Solo Istio install (one per cluster). |
| \`Gateway\` (\`istio-eastwest\` / \`istio-remote\`) | gateway.networking.k8s.io | East-west GW + per-remote peer references. Solo Istio peering primitives. |
| \`Gateway\` (\`istio-waypoint\` / \`agentgateway-waypoint\`) | gateway.networking.k8s.io | Per-agent waypoints that enforce AccessPolicy. |
| \`HTTPRoute\` | gateway.networking.k8s.io | Wires agentgateway HTTP routes. |
| \`Workspace\` / \`WorkspaceSettings\` | admin.gloo.solo.io | Solo Mesh governance scope (not federation — that's Solo Istio's job now). |
| \`KubernetesCluster\` | admin.gloo.solo.io | Solo Mesh's per-cluster registration. |
| \`Agent\` / \`ModelConfig\` / \`RemoteMCPServer\` | kagent.dev/v1alpha2 | Agent + model + MCP server declarations. |
| \`AccessPolicy\` | policy.kagent-enterprise.solo.io | **Defence layer 3** — per-agent invocation allowlist. SPIFFE-aware. |
| \`AgentgatewayPolicy\` / \`AgentgatewayBackend\` | agentgateway.dev | **Defence layer 2** — MCP tool / method filtering. |
| \`AuthorizationPolicy\` | security.istio.io | Mesh-level L4 ALLOW/DENY by SPIFFE identity. |
| \`Telemetry\` | telemetry.istio.io | Routes mesh telemetry to OTel collector. |
| \`PodMonitor\` / \`PrometheusRule\` / \`AlertmanagerConfig\` | monitoring.coreos.com | Observability stack — fires \`KagentAccessPolicyDeny\` on waypoint 403s. |
| \`Secret\` (\`cacerts\`, \`solo-istio-license\`, \`istio-remote-secret-*\`) | core | Critical multi-cluster glue. See file comments for what each must contain. |
TOP_README

(cd "$MULTI" && zip -qr "$OUT_DIR/trustusbank-multi-cluster.zip" . -x "*.DS_Store")
cd "$REPO_ROOT"
rm -rf "$MULTI"
SIZE=$(du -h "$OUT_DIR/trustusbank-multi-cluster.zip" | cut -f1)
echo "    wrote $OUT_DIR/trustusbank-multi-cluster.zip ($SIZE)"

echo ""
echo "Bundles ready in $OUT_DIR/."
