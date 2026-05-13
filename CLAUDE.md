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
| Cross-cluster connectivity | Solo Istio **Ambient peering** — east-west GW (`gatewayClassName: istio-eastwest`, ztunnel-backed, port 15008 HBONE + 15012 XDS) + `istio-remote-secret-*` for control-plane discovery (`scripts/multi/04-peering.sh` + `04b-remote-secrets.sh`) | Manual NodePort + `EndpointSlice` "lateral hack" (strips SPIFFE on SNAT) |
| Cross-cluster federation | Solo Istio **native** auto-discovery — istiod reads remote clusters via remote-secret, auto-rewrites endpoints to point at the producer's east-west GW. Services reachable as `<svc>.<ns>.svc.<cluster>.mesh.internal` (cluster-scoped) or `<svc>.<ns>.mesh.internal` (global, when labelled `istio.io/global=true`) | Solo Mesh `VirtualDestination` / `Workspace.federation` — that's the older translator path; for Ambient it conflicts with istiod-native peering and produces 0-endpoint SEs |
| License delivery to istiod | `SOLO_LICENSE_KEY` env var on `istiod-gloo` Deployment, sourced from the `solo-istio-license` Secret in istio-system (`key: license`). License JWT must be `lt: ent` (not `gloo-trial`) for MultiCluster to unlock. | Mounting at `/etc/license-keys/*` or using `LICENSE_KEY` / `GLOO_LICENSE_KEY` — the binary doesn't read these (verified by strings on the pilot binary) |
| Multi-cluster identity | Shared root CA + per-cluster intermediates **all signed with SAN `spiffe://cluster.local/...`** + per-cluster `clusterID` / `network`. The intermediate's signing key differs per cluster, the trust-domain SAN does not. | Distinct per-cluster trust domains (`bank.local`, `edge.local`, `vendor.local`) — breaks waypoint CA fetch AND breaks Solo Istio peering's cert-chain validation |
| Network classification | `topology.istio.io/network=<cluster>` label on **every workload namespace** (codified in `scripts/multi/05-namespaces.sh`) | Labeling only `istio-system` — istiod can't classify pod network, never rewrites cross-cluster endpoints |
| Agent governance / runtime AuthZ | `policy.kagent-enterprise.solo.io/AccessPolicy` (waypoint enforcement, identity-aware) | Hand-written `AuthorizationPolicy` per agent |
| MCP routing + tool allow-list | Solo `agentgateway` + `AgentgatewayPolicy` (CEL on `mcp.tool.name`, `mcp.method`) | Per-agent network policies or in-app filters |
| Image distribution + signing | Solo `agentregistry` + cosign | Plain registry + admission policy |
| Observability | kube-prometheus-stack + `PrometheusRule` + `AlertmanagerConfig` → MailHog | Custom alert pipelines |

### Known integration gaps

These exist because Solo's components don't auto-wire in some combinations. All
are codified in install scripts. The rationale comments stay in the scripts so
future maintainers see why each line is there.

1. **`istiod` alias Service** *(codified in `03-gloo-operator.sh`)* — Gloo
   Operator names istiod `istiod-gloo` but the EAG waypoint binary hardcodes
   `CA_ADDRESS=istiod.istio-system.svc:15012`. Fix: alias Service.

2. **Trust domain locked to `cluster.local`** *(codified in `02-shared-ca.sh`
   and `03-gloo-operator.sh`)* — EAG waypoint hardcodes
   `TRUST_DOMAIN=cluster.local` (no chart knob), and Solo Istio's cross-cluster
   cert-chain validation requires that the intermediate CA's SAN match the
   runtime trust domain. Fix: lock SMC `trustDomain: cluster.local`, generate
   all intermediates with SAN `spiffe://cluster.local/ns/istio-system/sa/citadel`.
   Per-cluster identity stays unique via the per-cluster intermediate key + the
   `clusterID` env.

3. **`CLUSTER_ID` env on waypoint Deployments** *(codified in
   `policies-kagent-on.sh`)* — agentgateway binary defaults to
   `ClusterID="Kubernetes"`; istiod-gloo expects `"<cluster>"`.

4. **License env var name is `SOLO_LICENSE_KEY`** *(codified in
   `03-gloo-operator.sh`)* — istiod-gloo's binary reads `SOLO_LICENSE_KEY`, not
   `LICENSE_KEY` / `GLOO_LICENSE_KEY` / `GLOO_MESH_LICENSE_KEY`. The Solo docs
   imply a volume mount at `/etc/license-keys/<file>` works too; the file path
   does NOT in fact work for the Solo Istio (`pilot-discovery`) binary on
   v1.29.2-patch0-solo, confirmed by `strings` on the binary. SMC's reconciler
   leaves the env var alone once added.

5. **Ambient peering requires both data-plane AND control-plane wiring**
   *(codified in `04-peering.sh` + new `04b-remote-secrets.sh`)* — the
   `peering` helm chart only provisions the east-west GW + remote Gateway CRs
   (data plane). Without `istio-remote-secret-*` Secrets cross-applied across
   every cluster pair, each istiod-gloo's "Number of remote clusters" stays
   at 0 — services are visible in the local registry but get no remote
   endpoints. `04b-remote-secrets.sh` generates a long-lived token bound to
   `istio-reader-service-account` and applies the kubeconfig Secret to every
   peer cluster.

6. **`topology.istio.io/network` label must be on EVERY workload namespace**
   *(codified in `05-namespaces.sh`)* — without it, istiod can't classify
   remote pods' networks, so endpoint rewriting never fires and cross-cluster
   services resolve to a VIP with zero endpoints.

7. **`L7_ENABLED=true` on ztunnel + `PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES=false`
   on istiod** *(codified in `03-gloo-operator.sh`)* — both required for
   Ambient peering per Solo troubleshooting docs. The SMC schema doesn't
   expose either knob — they're patched on directly after install.

### Architecture decision: Solo Istio peering owns federation, not Solo Mesh

Earlier iterations layered Solo Mesh's `VirtualDestination` / `Workspace`
federation translator on top of Solo Istio's Ambient peering. That layering
**doesn't work** at 2.12 — the two products fight (the translator emits
ServiceEntries with the right shape but zero endpoints, because its
gateway-discovery doesn't recognise the Ambient ztunnel-based east-west GW).

**Current architecture:** Solo Istio Ambient peering is the federation
primitive. Pod-to-pod cross-cluster traffic uses `<svc>.<ns>.svc.<cluster>.mesh.internal`
hostnames (cluster-scoped) or `<svc>.<ns>.mesh.internal` (global, when the
producer Service is labelled `istio.io/global=true`). Solo Mesh stays in the
picture for *governance* — `Workspace`, `WorkspaceSettings` (RBAC/imports),
`AccessPolicy` — but no longer touches data-plane federation.

The lateral-hack and `scripts/multi/apply-lateral-hack.sh` are **gone**.
SPIFFE is preserved end-to-end now, so cross-cluster `AccessPolicy` with
`kind: ServiceAccount` subjects works.

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
