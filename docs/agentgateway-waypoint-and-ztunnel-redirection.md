# AgentGateway as an Istio Waypoint + Ztunnel Traffic Redirection

**A consolidated technical reference**

Source material:
- `https://gist.github.com/rvennam/6cf84236bb56c1d2468f70cf035cd41b` (Solo internal workshop — AgentGateway as Istio Waypoint)
- `https://istio.io/latest/docs/ambient/architecture/traffic-redirection/` (Istio 1.29 — Ztunnel traffic redirection)

---

## Part 1 — AgentGateway as an Istio Waypoint

### The Core Idea in One Paragraph

Ambient mesh has two planes: **ztunnel** (per-node L4 mTLS, HBONE tunnels) and an optional **waypoint** (per-namespace or per-service L7 proxy). The waypoint has historically been Envoy. This work makes **agentgateway pluggable as the waypoint** via a new `GatewayClass: enterprise-agentgateway-waypoint`. Result: every L7 capability agentgateway has at the north-south edge (LLM routing, MCP awareness, prompt guards, GenAI observability, AI-aware rate limiting) now applies to **service-to-service traffic inside the mesh**, with the caller's SPIFFE identity already proven by mTLS at ztunnel.

That last point is the killer. North-south you authenticate via JWTs, API keys, headers — all forgeable, all the agent's responsibility. East-west via the waypoint, **identity is cryptographic and ambient**. The agent literally cannot lie about who it is.

### Architecture — Three-Hop Data Path

Mental model, agent pod calling an MCP server with a waypoint in front:

```
Agent Pod ──(plain HTTP)──> ztunnel(src) ──HBONE/mTLS──> AGW Waypoint ──HBONE/mTLS──> ztunnel(dst) ──> MCP Pod
   │                            │                              │                          │
   │                       L4 intercept                  L7 enforcement              decapsulate
   │                       (transparent)                 (authz, RL, headers,             │
   │                                                      LLM routing, MCP)               │
```

Five hops, breaking it down:

1. **Agent → source ztunnel**: agent sends plain HTTP. Agent has no clue a mesh exists. ztunnel intercepts at L4 via the istio-cni redirection.
2. **Source ztunnel → waypoint**: ztunnel looks up the destination service, sees `istio.io/use-waypoint=agw-waypoint`, and wraps the request in **HBONE** — that's HTTP/2 CONNECT over mTLS, port 15008. The agent's SPIFFE ID is on the client cert.
3. **Waypoint (L7 processing)**: agentgateway terminates the HBONE tunnel, extracts the SPIFFE identity from the peer cert, and runs the policy chain — authz → rate limit → header mods → routing. **Denies happen here in ~0ms** before any proxy to the backend.
4. **Waypoint → destination ztunnel**: if allowed, agentgateway opens a **second HBONE tunnel** to the ztunnel on the destination node. The waypoint's own SPIFFE ID is now the source identity on this leg.
5. **Destination ztunnel → backend pod**: decapsulate, deliver as plain HTTP.

**Two separate mTLS legs, two SPIFFE identity hops.** This is important for audit — the waypoint logs show the *original* caller identity (extracted in step 3), not the waypoint's own identity. Customers will ask about this.

### How It's Wired — The Configuration Stack

Four resources do the work.

**1. The Gateway** (waypoint declaration):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agw-waypoint
  namespace: ai-tools
  labels:
    istio.io/waypoint-for: service   # service-level scope
spec:
  gatewayClassName: enterprise-agentgateway-waypoint  # ← swaps Envoy for AGW
  listeners:
  - name: mesh
    protocol: HTTP
    port: 15088                       # standard waypoint listener
```

`port 15088` is the inbound listener; HBONE termination still happens on `15008`. Don't confuse these.

**2. The opt-in label** — this is what causes ztunnel to route through the waypoint:

```bash
# Per-service
kubectl label svc inventory-mcp -n ai-tools istio.io/use-waypoint=agw-waypoint

# Or per-namespace (auto-protects everything, including new deploys)
kubectl label ns ai-tools istio.io/use-waypoint=agw-waypoint
```

Note: **ServiceEntries need their own label even when the namespace is labelled**. The namespace label covers Services, not ServiceEntries.

**3. The policy** — `EnterpriseAgentgatewayPolicy`, targeting the Gateway:

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: waypoint-authz
  namespace: ai-tools
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agw-waypoint
  traffic:
    authorization:
      action: Allow
      policy:
        matchExpressions:
        - 'source.identity.serviceAccount == "customer-agent"'
```

CEL with mesh-native variables. Available identity fields: `source.identity.serviceAccount`, `source.identity.namespace`, `source.identity.trustDomain`, plus `source.address`, `source.port`, `request.method`, `request.path`, `request.headers`.

**Multiple expressions in `matchExpressions` are OR'd.** That's how you allow several service accounts. Use `&&` inside a single expression for AND logic.

**4. Routing for egress / multi-provider**:

```yaml
# ServiceEntry defines the virtual hostname
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: myllm
  labels:
    istio.io/use-waypoint: agw-waypoint   # ServiceEntry needs its own label
spec:
  hosts: [myllm.com]
  location: MESH_EXTERNAL
  resolution: STATIC
  endpoints: [{address: 1.1.1.1}]         # dummy — waypoint overrides
---
# HTTPRoute parentRef is the ServiceEntry, NOT the Gateway
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: llm-routes, namespace: ai-tools}
spec:
  parentRefs:
  - group: networking.istio.io
    kind: ServiceEntry
    name: myllm
  rules:
  - matches: [{path: {type: PathPrefix, value: /openai}}]
    backendRefs:
    - {name: openai, group: agentgateway.dev, kind: AgentgatewayBackend}
  - matches: [{path: {type: PathPrefix, value: /anthropic}}]
    backendRefs:
    - {name: anthropic, group: agentgateway.dev, kind: AgentgatewayBackend}
```

**Memorise this:** *in waypoint mode, HTTPRoute `parentRefs` target the ServiceEntry, not the Gateway.* It trips everyone up. The reason: istiod reconciles the route against the SE-defined hostname, and the agentgateway controller fans out backend config separately. Get this wrong and you'll see "route accepted, no traffic" symptoms.

The `endpoints: [1.1.1.1]` is a dummy. The SE just needs to exist so ztunnel knows about the hostname; the AgentgatewayBackend is what actually resolves and originates TLS.

### What the Waypoint Can Enforce (Confirmed Working Today)

| Capability | Mechanism | Real-world use |
|---|---|---|
| **SPIFFE-based authz** | `EnterpriseAgentgatewayPolicy` + CEL on `source.identity.*` | Stop rogue agent talking to MCP server |
| **Local rate limit** | `rateLimit.local` — requests or **tokens** per unit | Cap LLM spend per agent SA |
| **Global rate limit (req + token)** | `RateLimitConfig` + `entRateLimit` | Cluster-wide LLM token budgets |
| **Header modification** | `headerModifiers` | Inject `x-source-identity` for downstream apps |
| **CEL transformations** | `transformation` block | Stamp SPIFFE info as headers for legacy apps |
| **LLM egress routing** | HTTPRoute → `AgentgatewayBackend` per provider | `myllm.com/openai` vs `/anthropic` |
| **Per-backend API key injection** | `AgentgatewayBackend.policies.auth.secretRef` | Agents never see provider keys |
| **Prompt guards (regex)** | `AgentgatewayPolicy.backend.ai.promptGuard` | Block CC/SSN exfiltration |
| **GenAI observability** | Auto-logged: `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.usage.input_tokens` | Cost attribution per SA |
| **MCP-aware processing** | Auto on `AgentgatewayBackend` MCP type | Logs `protocol=mcp`, `mcp.method`, `mcp.session.id` |
| **Structured access logs** | JSON, port 15020 metrics, OTLP traces | DORA Article 28 audit trail |

### The Policy Evaluation Order

Order is fixed:

```
Request → [1] Authorization (CEL/SPIFFE) → [2] Rate Limit → [3] Header/Transform → Backend
              ↓ DENY: 403 (0ms)              ↓ EXCEED: 429
```

**Authz happens first, and it's effectively free.** A denied rogue agent never consumes a rate-limit token, never reaches an LLM, never costs you a dollar of OpenAI spend. That's the line for the cost-conscious CFO conversation: *"every blocked request is zero cost — we deny at the identity layer before any LLM call."*

### Waypoint vs North-South Gateway

Same agentgateway binary, different deployment, materially different capabilities:

| | North-South Gateway | Waypoint |
|---|---|---|
| GatewayClass | `enterprise-agentgateway` | `enterprise-agentgateway-waypoint` |
| Direction | External → cluster | Pod → pod |
| **Identity source** | JWT, API key, header (forgeable) | **SPIFFE via mTLS (cryptographic)** |
| Container model | 4 containers (ext-authz, RL sidecar, etc.) | **Single container** — RL is native |
| HTTPRoute parentRef | Gateway | ServiceEntry |
| LLM/MCP routing | Yes | Yes |
| Prompt guards | Yes | Yes |
| AuthorizationPolicy (Istio) | n/a | **Not yet supported** — use EnterpriseAgentgatewayPolicy |
| Licensing | Enterprise | **Enterprise-only — no OSS path** |

The single-container model is operationally significant. The north-south gateway pulls in ext-authz and rate-limiter as sidecars; the waypoint inlines both. Less memory, simpler debugging, fewer failure modes — but it does mean global rate limit (which uses an external RL service) needs the sidecar to come along, and **that is partially in flight today**.

### Lab-by-Lab Walkthrough Summary

The gist walks through 8 labs. Quick reference:

| Lab | What it shows | Key takeaway |
|---|---|---|
| 1 | Baseline — agents + MCP server, no waypoint | Without waypoint, ztunnel only does L4 mTLS — no L7 controls |
| 2 | Deploy AGW as waypoint, label service | Single label flip routes service traffic through L7 enforcement |
| 3 | CEL identity authz | `source.identity.serviceAccount == "customer-agent"` blocks rogue (403 in 0ms) |
| 4 | Local rate limiting | `requests: 2, unit: Minutes` — no EnvoyFilters needed |
| 5 | LLM egress with path-based routing | ServiceEntry + HTTPRoute + AgentgatewayBackend per provider; agents never see API keys |
| 6 | Stack policies (authz + RL + headers) | Multiple `EnterpriseAgentgatewayPolicy` resources compose cleanly |
| 7 | Observability | JSON access logs on port 15020, GenAI semconv, OTLP traces |
| 8 | Namespace-level waypoint | Label the namespace instead of services — auto-protects new deploys |

### What's Not Working Yet (Tell Customers Honestly)

Straight from the doc's roadmap table. Your "don't get caught" list:

- **Istio `AuthorizationPolicy` is ignored by the waypoint.** Critical gotcha — customers with existing Istio L7 authz cannot just label-and-go. They have to convert to `EnterpriseAgentgatewayPolicy`. Target: 1.30.
- **TrafficDistribution / PreferClose locality routing** — not done. Multi-cluster works for the basics (double-HBONE merged) but locality preferences for east-west don't apply yet.
- **`solo.io/service-scope`** — not done.
- **Unhealthy endpoint handling for WorkloadEntry** — not done.
- **FIPS-compliant AGW builds** — open questions. **This will be the blocker for UK/EU financial services and public sector.** Don't promise FIPS until it lands.
- **ArgoCD compatibility** — workaround identified, not productised. GitOps shops will hit this.
- **Conformance test suite** — design phase.
- **Documentation** — explicitly waiting on feature completion.

The install in the doc still uses a controller image override (`fix-waypoint-agw-backend`) — meaning AgentgatewayBackend as a backendRef from waypoint HTTPRoutes requires a non-default controller build right now. That ships properly at GA.

Version requirement: **Enterprise AgentGateway v2.3.0+**, on Solo Istio in ambient mode.

### Key Technical Notes (Solo's Own)

- **Waypoint is enterprise-only** — not available in OSS agentgateway
- **Single container** — unlike the north-south gateway (4 containers), the waypoint is a single agentgateway container
- **Gets identity from Istio CA** (istiod) with the cluster's trust domain
- **XDS configuration** from the enterprise-agentgateway control plane, not istiod

### Three-Plane Composition (Tying Back to the Stack)

When customers ask where this fits in Solo's agentic story:

- **Control plane (kagent)** — defines what agents *are* (CRDs reconciled by Go operators)
- **Data plane (agentgateway)** — moves agent traffic, enforces policy. **Waypoint mode = data plane *inside* the mesh, north-south gateway = data plane at the edge.** Same binary, two postures.
- **Catalog plane (agentregistry)** — governs which tools/MCP servers exist and who can use them

The waypoint story is specifically a data-plane evolution: agentgateway is no longer just an edge concern, it's now a *mesh-native* L7 enforcement point. Competitors who sell ingress AI gateways (Kong AI Gateway, Vercel) have nothing equivalent to east-west enforcement inside a service mesh.

### Customer Value

**Problem solved:** Enterprise customers running AI agents in Kubernetes today have zero L7 controls on east-west traffic. Sidecar-based meshes can do it but at a heavy operational cost; ambient mesh removed sidecars but until now offered only Envoy waypoints with no AI semantics. Customers were resorting to **unsupported EnvoyFilters** to get rate limiting east-west, or pushing all AI traffic through the north-south gateway artificially (creating a hairpin).

**Quantifiable benefits:**
- **Identity assurance**: SPIFFE-based authz removes JWT/API-key forgery risk for internal agent traffic — material for DORA Article 28 (ICT third-party risk) and NIS2 internal-controls evidence
- **Cost control**: token-based rate limits at the waypoint cap LLM spend per service account, denying *before* an OpenAI call — direct OpEx saving
- **Zero application change**: pods don't know the waypoint exists; ztunnel intercepts transparently — vs sidecar mesh migrations which touch every workload
- **Audit trail**: GenAI semantic-convention logs (`gen_ai.usage.input_tokens` per SPIFFE ID) give per-agent cost attribution and per-agent compliance evidence in one log stream

**Competitive differentiator:** Kong AI Gateway, Vercel AI Gateway, AWS Bedrock AgentCore — none of them sit inside a service mesh as an L7 enforcement point on east-west traffic with cryptographic identity. They're all north-south or runtime-scoped. **Solo's pitch: same agentgateway binary, same policy CRDs, same observability schema, applied to both directions of traffic.** One control surface for AI policy across ingress *and* service-to-service.

---

## Part 2 — Ztunnel Traffic Redirection (How It Actually Works)

### The Mental Correction

**Common misconception:** "Pods send traffic to ztunnel, which then sends it back out via the node's network."

**What actually happens:** ztunnel runs as a DaemonSet pod on each node, but the **listening sockets that intercept your application's traffic live *inside your application pod's own network namespace***. The ztunnel process opens those sockets remotely using a Linux file descriptor trick. So when your app sends a packet:

1. The packet **never leaves the pod's network namespace** as application traffic
2. iptables rules inside the pod's netns redirect it to a socket **also inside the pod's netns**
3. That socket is **owned by the ztunnel process** running on the node
4. ztunnel processes it, then sends it out — also from inside the pod's netns — as an HBONE tunnel

So yes — pods communicate with ztunnel, and the encrypted output exits the pod normally through standard pod networking. **There's no extra hop to a separate ztunnel pod on the same node.** The proxy listeners are co-located inside the application pod's netns.

This is the architectural breakthrough that makes Ambient work transparently with any CNI. Cilium, Calico, AWS VPC CNI — none of them need to know Istio exists. The redirect happens entirely inside the pod's own network namespace, after the primary CNI has already set up pod networking.

### The Pod Onboarding Sequence

The dance is between three actors: the **istio-cni node agent** (a DaemonSet), a **chained CNI plugin** (installed by the agent), and the **ztunnel proxy** (also a DaemonSet, one per node).

```
┌─────────────────────────────────────────────────────────────────┐
│ Node                                                            │
│                                                                 │
│  ┌──────────────────┐    ┌──────────────────┐                  │
│  │ istio-cni        │    │ ztunnel          │                  │
│  │ (node agent      │◄──►│ (node proxy      │                  │
│  │  DaemonSet)      │UDS │  DaemonSet)      │                  │
│  └────────┬─────────┘    └────────┬─────────┘                  │
│           │                       │                            │
│           │ 1. enter pod netns    │ 3. open sockets            │
│           │ 2. install iptables   │    in pod netns            │
│           │                       │    via netns FD            │
│           ▼                       ▼                            │
│  ┌────────────────────────────────────────────────┐            │
│  │ Application Pod (network namespace)            │            │
│  │                                                │            │
│  │  ┌──────┐                                      │            │
│  │  │ app  │──► iptables (ISTIO_OUTPUT/PRERT)     │            │
│  │  └──────┘         │                            │            │
│  │                   ▼                            │            │
│  │     listening sockets owned by ztunnel:        │            │
│  │     :15001 (egress)  :15006 (plaintext in)     │            │
│  │     :15008 (HBONE in)                          │            │
│  └────────────────────────────────────────────────┘            │
└─────────────────────────────────────────────────────────────────┘
```

The clever bit: **istio-cni passes ztunnel a file descriptor** referencing the pod's network namespace over a Unix domain socket (`/var/run/ztunnel/ztunnel.sock`). ztunnel then uses Linux's low-level socket API to open listening sockets *in that target namespace* despite the ztunnel process itself running in a different namespace. From the application's perspective those sockets look local — because they are.

Each pod gets its own dedicated **logical proxy instance and listen port set** inside the single ztunnel process. Same Rust process, separate task per pod, separate sockets per pod's netns. That's why you see one ztunnel pod per node but thousands of policy decisions.

### Onboarding Steps (Exact Sequence)

1. The **`istio-cni` node agent** responds to CNI events (pod creation/deletion) and watches the Kubernetes API for the ambient label being added to a pod or namespace.
2. `istio-cni` also installs a **chained CNI plugin** that runs after the primary CNI plugin. Its only job is to notify `istio-cni` when a new pod is created in an ambient-enrolled namespace.
3. When notified, `istio-cni` **enters the pod's network namespace** and establishes redirect rules — iptables rules that send packets to/from the pod through ztunnel listening ports `15008`, `15006`, `15001`.
4. `istio-cni` then informs **ztunnel** over a **Unix domain socket** that it should establish proxy listening ports inside the pod's netns, passing along a **Linux file descriptor** for that netns.
5. The node-local ztunnel spins up a **logical proxy instance** for that pod — still the same process, but a dedicated task with dedicated sockets bound inside the pod's netns.
6. Once redirect rules are in place and ztunnel has its listeners, the pod is "in the mesh" — all its traffic is intercepted, mTLS encrypted, and policy-enforced.

### The Three Ports

| Port | Purpose | Direction |
|---|---|---|
| **15001** | Outbound egress traffic from the app | App → ztunnel (egress) |
| **15006** | Inbound **plaintext** traffic (for legacy/non-mesh callers) | Caller → ztunnel (ingress, plaintext) |
| **15008** | Inbound **HBONE-encapsulated** traffic from another ztunnel/waypoint | Caller → ztunnel (ingress, encrypted) |

Plus `15080` on localhost for ztunnel's own health/admin.

### The iptables Rules — What's Actually Doing the Redirect

Inside the pod's netns there's an `ISTIO_OUTPUT` chain on the NAT/Mangle tables and an `ISTIO_PRERT` chain.

**Egress** (app sending out):

```
-A ISTIO_OUTPUT ! -d 127.0.0.1/32 -p tcp -m mark ! --mark 0x539/0xfff -j REDIRECT --to-ports 15001
```

Any TCP traffic the app sends (that isn't to localhost and isn't already marked as ztunnel-originated) gets REDIRECTed to port 15001. The connection mark `0x539` is how ztunnel's *own* outbound traffic avoids being redirected back to itself. Without that mark check you'd loop forever.

**Ingress** (traffic arriving at the pod):

```
-A ISTIO_PRERT -p tcp -m tcp --dport 15008 -m mark ! --mark 0x539/0xfff -j TPROXY --on-port 15008 ...
-A ISTIO_PRERT ! -d 127.0.0.1/32 -p tcp -m mark ! --mark 0x539/0xfff -j TPROXY --on-port 15006 ...
```

HBONE traffic (`:15008`) is TPROXYed to ztunnel's HBONE listener. Plaintext goes to `:15006`. **TPROXY is used (not REDIRECT)** because ztunnel needs to see the *original destination* to know where the request was actually headed — REDIRECT would rewrite the destination address, TPROXY preserves it.

### Debugging Commands

Quick triage when traffic isn't behaving:

```bash
# Check ztunnel is aware of a pod
kubectl logs ds/ztunnel -n istio-system | grep inpod

# Verify the redirect sockets are listening inside the app pod
kubectl debug $POD --image nicolaka/netshoot -- ss -ntlp
# Expect: :15001, :15006, :15008 LISTEN

# Inspect the actual iptables rules inside the pod's netns
kubectl debug $POD --image gcr.io/istio-release/base \
  --profile=netadmin -- iptables-save
```

If `ss -ntlp` doesn't show those three ports, ztunnel never received the netns FD from istio-cni — that's the failure point to investigate. Common cause: pod scheduled before istio-cni was ready on the node, or the chained CNI plugin isn't installed properly.

Expected ztunnel log output for a working pod:

```
inpod_enabled: true
inpod_uds: /var/run/ztunnel/ztunnel.sock
inpod_port_reuse: true
inpod_mark: 1337
INFO ztunnel::inpod::workloadmanager: handling new stream
INFO ztunnel::inpod::statemanager: pod WorkloadUid("...") received netns, starting proxy
INFO ztunnel::inpod::statemanager: pod received snapshot sent
```

---

## Part 3 — Stitching It Together

The full picture, combining ztunnel redirection mechanics with the waypoint flow:

```
Pod A (ai-agents/customer-agent)              Pod B (ai-tools/inventory-mcp)
┌──────────────────────────────┐              ┌──────────────────────────────┐
│ App: curl http://inv-mcp/sse │              │ App: MCP server :8000        │
│  │                           │              │  ▲                           │
│  ▼ iptables REDIRECT         │              │  │ delivered as plain HTTP   │
│ :15001 (ztunnel egress       │              │  │                           │
│        listener IN POD NETNS)│              │ :15006 or :15008 (ztunnel    │
│   - mTLS handshake           │              │        listener IN POD NETNS)│
│   - HBONE encapsulation      │              │   - decapsulate HBONE        │
│   - destination: waypoint    │              │   - terminate mTLS           │
│  │                           │              │   - hand off to app socket   │
│  ▼ packets EXIT pod netns    │              └──────────▲───────────────────┘
└────────────────────────────────┐                       │
                                 │                       │
                                 │   normal pod-to-pod   │
                                 │   networking (CNI)    │
                                 │                       │
                                 ▼                       │
                    ┌──────────────────────────────────┐ │
                    │ AGW Waypoint pod (ai-tools)      │ │
                    │  :15008 HBONE in                 │ │
                    │   - terminate mTLS               │ │
                    │   - extract SPIFFE ID of caller  │ │
                    │   - L7 policy: authz, RL, headers│ │
                    │   - if allowed: open NEW HBONE   │ │
                    │     tunnel to dest ztunnel       │ │
                    └──────────────┬───────────────────┘ │
                                   │                     │
                                   └─────────────────────┘
```

### The Key Insight

Once ztunnel has encapsulated the traffic into HBONE, the packets that leave the pod's network interface are just normal TCP packets carrying an HTTP/2 CONNECT tunnel over mTLS, destined for another IP address. They traverse standard pod networking, standard CNI, standard cloud SDN. No tunnels, no overlays, no node-level routing tables to maintain. **That's why Ambient is CNI-agnostic.**

The "ztunnel-ness" of the traffic exists at two endpoints (the source pod's netns and the destination pod's netns, both via the node-local ztunnel process) — but in between it's just packets.

### Why This Matters for the Waypoint Story

The waypoint sits in the middle. When ztunnel (running listeners inside Pod A's netns) decides to forward traffic to a destination that has `istio.io/use-waypoint=agw-waypoint` set, it doesn't open the HBONE tunnel directly to Pod B's ztunnel. It opens it to the **waypoint pod**. The waypoint is the L7 enforcement point. After processing, the waypoint opens a *second* HBONE tunnel to the destination ztunnel.

So the flow is:

- **Hop 1**: App in Pod A → iptables REDIRECT → ztunnel listener (in Pod A's netns) → HBONE tunnel → Waypoint
- **Hop 2**: Waypoint → HBONE tunnel → ztunnel listener (in Pod B's netns) → app in Pod B

Both ztunnel "endpoints" are just listening sockets inside the respective pod netns, owned by the node-local ztunnel process. The waypoint is a normal Kubernetes pod (running agentgateway in its specialised waypoint mode) reached over standard pod networking.

### Auditable Identity Chain

- **Pod A's SPIFFE ID** is presented as the client cert on Hop 1 (because ztunnel's listener inside Pod A's netns has access to Pod A's identity from the Istio CA via istiod)
- **Waypoint extracts that identity** for policy decisions and logs it (`source.identity.serviceAccount`)
- **Waypoint's own SPIFFE ID** is presented as the client cert on Hop 2
- **Pod B's ztunnel** records the waypoint's identity as the immediate peer, but the waypoint logs preserve the original caller

For DORA Article 28 evidence, what you show the auditor is the **waypoint's structured access log** — one record per request, with original SPIFFE caller identity, target service, route, decision, latency, and (for AI traffic) token counts.

---

## Quick Reference

### Critical Ports

| Port | Component | Purpose |
|---|---|---|
| 15001 | ztunnel | Outbound egress (REDIRECT from app) |
| 15006 | ztunnel | Inbound plaintext (TPROXY) |
| 15008 | ztunnel | Inbound HBONE / mTLS (TPROXY) |
| 15020 | waypoint | Prometheus metrics, health |
| 15080 | ztunnel | localhost admin |
| 15088 | waypoint | Mesh HTTP listener (Gateway listener port) |

### Critical Labels

| Label | Applied to | Effect |
|---|---|---|
| `istio.io/dataplane-mode=ambient` | Namespace | Enrols all pods in ambient mesh |
| `istio.io/use-waypoint=<name>` | Service / Namespace / ServiceEntry | Routes L7 traffic through named waypoint |
| `istio.io/waypoint-for=service` | Gateway (waypoint) | Scopes waypoint to service-level traffic |
| `istio.io/ingress-use-waypoint` | Service | Routes ingress traffic through waypoint |

### Critical CRDs

| CRD | Group | Purpose |
|---|---|---|
| `Gateway` | `gateway.networking.k8s.io/v1` | Declares the waypoint (with `gatewayClassName: enterprise-agentgateway-waypoint`) |
| `HTTPRoute` | `gateway.networking.k8s.io/v1` | Routes within the waypoint (parentRef = ServiceEntry in waypoint mode) |
| `ServiceEntry` | `networking.istio.io/v1` | Virtual hostname for external/non-K8s destinations |
| `AgentgatewayBackend` | `agentgateway.dev/v1alpha1` | Backend definition (AI provider, MCP server, etc.) |
| `EnterpriseAgentgatewayPolicy` | `enterpriseagentgateway.solo.io/v1alpha1` | Authz, rate limit, header mods, transformations |
| `AgentgatewayPolicy` | `agentgateway.dev/v1alpha1` | Prompt guards, backend-targeted policies |
| `RateLimitConfig` | `enterpriseagentgateway.solo.io/v1alpha1` | Global rate limit configuration |

### Customer-Facing Talking Points

1. **One control surface for AI policy** — same agentgateway binary, same CRDs, same observability schema, applied to both north-south *and* east-west traffic.
2. **Cryptographic identity east-west** — SPIFFE via mTLS, not forgeable JWTs/API keys. Material for DORA Article 28 and NIS2 internal-controls evidence.
3. **Zero application change** — ztunnel intercepts transparently inside the pod's own netns. No sidecar injection, no application restarts, works with any CNI.
4. **Cost control where it matters** — token-based rate limits deny *before* the LLM call. Every blocked request is zero OpEx.
5. **Audit-ready logs** — GenAI semantic-convention fields (`gen_ai.provider.name`, `gen_ai.usage.input_tokens`) keyed by SPIFFE identity. One log stream feeds both cost attribution and compliance evidence.

### Open Questions to Track Before GA

- FIPS-compliant AGW builds (blocker for UK/EU financial services, public sector)
- Istio `AuthorizationPolicy` support on the waypoint (migration path for existing customers)
- TrafficDistribution / PreferClose locality (multi-cluster east-west)
- ArgoCD compatibility (GitOps shops)
- Token counting behaviour on streaming responses (SSE / chunked) when quota exceeds mid-flight

---

*Document compiled from two source pages: Solo internal workshop on AgentGateway-as-waypoint, and the Istio 1.29 ambient traffic redirection architecture page. Verify against current Solo docs (`agentgateway.dev/docs`) and the Istio ambient docs before quoting to customers — both products are moving fast.*
