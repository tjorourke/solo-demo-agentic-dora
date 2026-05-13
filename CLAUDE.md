# Project guidance for assistants

## Use Solo's products and Solo's documented patterns throughout

This repo is a customer-facing reference for "how Solo's stack does agentic AI
on Kubernetes under DORA-style runtime governance". Every shortcut undermines
that value. When implementing or fixing something, default to Solo's
documented best-practice pattern; if you hit an integration gap, codify the
patch in the install script with a comment explaining the gap — don't abandon
the Solo path.

### Defaults to use

| Concern | Solo pattern (use this) | Anti-pattern (avoid) |
|---|---|---|
| Mesh install | Gloo Operator + `ServiceMeshController` CR (`scripts/multi/03-gloo-operator.sh`) | Raw `helm install istio-base/istiod/istio-cni/ztunnel` |
| Cross-cluster connectivity | Solo Istio **east-west HBONE peering** on port 15008 (preserves SPIFFE, mTLS end-to-end) + `solo.io/expose-cross-cluster=true` on the Services that should be reachable | Manual NodePort + `EndpointSlice` "lateral hack" — strips SPIFFE on SNAT |
| Cross-cluster federation | Solo's `Workspace` + `WorkspaceSettings` with `federation.serviceSelector` narrowed to opt-in labels | `solo.io/service-scope=global` namespace-wide (hijacks all Services) |
| Multi-cluster identity | Shared root CA + per-cluster intermediates + per-cluster `clusterID` / `network` (trustDomain can be the same `cluster.local`; the operator's enterprise-agentgateway hardcodes that) | Distinct per-cluster trust domains (breaks waypoint CA fetch) |
| Agent governance / runtime AuthZ | `policy.kagent-enterprise.solo.io/AccessPolicy` (waypoint enforcement, identity-aware) | Hand-written `AuthorizationPolicy` per agent |
| MCP routing + tool allow-list | Solo `agentgateway` + `AgentgatewayPolicy` (CEL on `mcp.tool.name`, `mcp.method`) | Per-agent network policies or in-app filters |
| Image distribution + signing | Solo `agentregistry` + cosign | Plain registry + admission policy |
| Observability | kube-prometheus-stack + `PrometheusRule` + `AlertmanagerConfig` → MailHog | Custom alert pipelines |

### Known integration gaps

These exist because Solo's components don't auto-wire in some combinations. Codified
in install scripts where possible; documented here where they need a chart-version
bump or Solo support to resolve cleanly.

1. **`istiod` alias Service** *(fixable, codified)* — Gloo Operator names istiod
   `istiod-gloo` but the EAG waypoint binary hardcodes
   `CA_ADDRESS=istiod.istio-system.svc:15012`. Fix: alias Service in
   `scripts/multi/03-gloo-operator.sh`.

2. **Trust domain locked to `cluster.local`** *(fixable, codified)* — EAG waypoint
   hardcodes `TRUST_DOMAIN=cluster.local` env (no chart knob). Fix: lock SMC
   `trustDomain: cluster.local`. Multi-cluster identity stays unique via
   `clusterID` + shared root CA.

3. **`CLUSTER_ID` env on waypoint Deployments** *(fixable, codified)* — agentgateway
   binary defaults to `ClusterID="Kubernetes"`; istiod-gloo expects `"<cluster>"`.
   Fix: `scripts/policies-kagent-on.sh` injects `CLUSTER_ID` after waypoints spawn.

4. **Federation translator can't find east-west Gateway** *(unresolved, lateral-hack
   covers it)* — Solo Mesh's mgmt-server federation translator runs against a
   live snapshot from each cluster's relay agent. When it tries to publish a
   service from bank to edge, it emits a `ServiceEntry` with proper
   `subjectAltNames` (SPIFFE-preserving) — but the matching `WorkloadEntry`
   never appears, and the `VirtualDestination`'s status reports:

   > virtual destination has backing services in cluster [trustusbank-bank],
   > but no gateway to reach services in that cluster could be found

   Root cause: the federation translator's gateway-discovery logic doesn't
   recognise the east-west Gateway created by Solo Istio's `peering` helm
   chart (the one applied by `scripts/multi/04-peering.sh`). That GW is a
   `gateway.networking.k8s.io/v1 Gateway` with `gatewayClassName: istio-eastwest`
   — works fine for raw Istio Ambient HBONE, but mgmt-server expects either an
   older Solo Mesh-style east-west GW (different chart) or a registration via
   the `KubernetesCluster` CR that this build doesn't auto-populate.

   The federation CRs (Workspace, WorkspaceSettings with `solo.io/expose-cross-cluster`
   selector, Segment, VirtualDestination, per-Service labels) ARE the right
   shape — they're what a working Solo Mesh federation looks like. The piece
   that's missing is gateway discovery on mgmt-server's side. Either:
   - Use Solo Mesh's bundled east-west GW chart instead of Solo Istio's peering
     chart (need to confirm Ambient compatibility), or
   - Manually populate the gateway address in the `KubernetesCluster` status
     (requires patching status which is non-trivial), or
   - File a Solo support ticket — this is a real integration gap.

   **Working path until that's resolved:** `scripts/multi/apply-lateral-hack.sh`
   plants stub Services + manual EndpointSlices that route via NodePort. This
   strips SPIFFE on SNAT, so AccessPolicy with `kind: ServiceAccount` subject
   won't match a cross-cluster caller — but it gets the demo functional end-to-end.
   Intra-cluster AccessPolicy enforcement is unaffected and is the actual point of
   the rug-pull defence story.

### Rollback

Tag `pre-gloo-operator` is the helm-based install snapshot. Use `git checkout pre-gloo-operator` if the operator path needs to be backed out.

### Demo flow this repo demonstrates

Three independent rug-pull defence layers (any one defeats the attack; in
production run all three):

1. **Admission** — cosign signature check on every MCP image
2. **Gateway** — `AgentgatewayPolicy` filters tool calls at the agentgateway L7 waypoint
3. **Agent runtime** — `AccessPolicy` denies disallowed callers at the per-agent waypoint Gateway

Scripts: `policies-on.sh` (layer 2), `policies-kagent-on.sh` (layer 3). They
toggle independently so the demo can show each layer catching the rug-pull
from a different angle.
