# Cross-cluster A2A with kagent: BYO stub Agents + lateral-hack EndpointSlices

A pattern for distributing kagent Agents across multiple clusters while keeping
A2A (Agent-to-Agent) tool references intact, given the current kagent API's
local-cluster CRD validation rule.

This pattern is what's running in the [multi-cluster training walkthrough](multi-cluster.html)
under §8 (distributing agents across clusters). The write-up here is the
standalone reference.

---

## The use case

The TrustUsBank demo distributes three kagent Agents across three kind clusters:

| Agent          | Cluster              | Real pod runs here? |
|----------------|----------------------|---------------------|
| `support-bot`  | `trustusbank-edge`   | yes                 |
| `fraud-bot`    | `trustusbank-bank`   | yes                 |
| `triage-bot`   | `trustusbank-bank`   | yes                 |

`support-bot` is the customer-facing agent. When it sees something suspicious
in a transaction list, its LLM is meant to hand off to `fraud-bot`, which can
then escalate to `triage-bot`. That hand-off happens over A2A — a `POST /` to
the receiving agent's Service.

The interesting bit is that `support-bot`'s declarative spec on edge lists
`fraud-bot` and `triage-bot` as *Agent-type* tools — and that's where kagent's
current API design collides with the multi-cluster topology.

---

## The problem

`support-bot`'s Agent CRD on edge looks like this (abridged):

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: support-bot
  namespace: trustusbank-bank-agents
spec:
  type: Declarative
  declarative:
    modelConfig: anthropic-haiku
    systemMessage: "You are TrustUsBank's customer support assistant..."
    tools:
      - type: McpServer
        mcpServer:
          name: account-mcp
          toolNames: [get_balance, get_profile]
      - type: McpServer
        mcpServer:
          name: transaction-mcp
          toolNames: [list_recent]
      - type: Agent
        agent: { name: fraud-bot }     # <-- triggers a local CRD lookup
      - type: Agent
        agent: { name: triage-bot }    # <-- and this one too
```

When the kagent controller on **edge** admits this Agent, it validates every
tool reference. For `type: Agent` tools, it asks the local Kubernetes API server:

> *"Does an `Agent` named `fraud-bot` exist in `trustusbank-bank-agents`?"*

If the answer is no, the admission is rejected:

```
Agent "support-bot" rejected: tool reference fraud-bot — Agent not found in namespace
```

That's the catch. The real `fraud-bot` Agent CRD lives on the **bank** cluster's
API server, not edge's. kagent has no native concept of a "remote Agent
reference" — Agent tool refs are resolved by name in the **same cluster**,
**same namespace**.

So out of the box, you cannot have `support-bot` on edge reference `fraud-bot`
on bank.

---

## Why the simpler workarounds don't work

A few obvious ideas, and why each fails:

1. **Move `support-bot` to the bank cluster.**  
   Defeats the purpose of distributing agents — the whole point of the demo is
   that the customer-facing pod sits on a different trust boundary from the
   bank's internal agents.

2. **Drop the `fraud-bot` / `triage-bot` tool references from `support-bot`.**  
   Then `support-bot` has no way to invoke them. The hand-off scenario the LLM
   is supposed to trigger goes away.

3. **Create a `type: Declarative` Agent on edge for `fraud-bot` with
   `replicas: 0`.**  
   kagent rejects it: *"Declarative Agent requires `replicas ≥ 1`."* The
   validator demands a runnable pod spec for declarative agents.

4. **Create a `type: External` or `type: Remote` Agent on edge.**  
   Not in the current kagent CRD schema. There is no public way to declare an
   Agent that points at a remote URL.

---

## The pattern: BYO stub on the consumer cluster + lateral-hack routing

The one Agent type kagent accepts with `replicas: 0` is `type: BYO` ("Bring Your
Own"). It's intended for cases where the user runs their own agent pod
(side-loaded, not kagent-managed) and just wants kagent to record the Agent's
existence and create a routing Service.

We exploit that exact behaviour to plant a **stub** on edge for every name
`support-bot` references:

```yaml
# edge: stub Agent so kagent's controller can resolve "fraud-bot" by name.
# No pod ever runs - the Deployment has replicas=0.
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: fraud-bot
  namespace: trustusbank-bank-agents
spec:
  type: BYO
  byo:
    deployment:
      image: registry.k8s.io/pause:3.9     # placeholder, never runs
      replicas: 0
```

The kagent controller on edge sees this and:

1. Creates a `Deployment` with 0 replicas (no pod, no resource cost).
2. Creates a `Service` named `fraud-bot` in `trustusbank-bank-agents` — that
   Service has no endpoints because no pod is running, but it exists, has a
   ClusterIP, and DNS resolves it.

The Service is what we actually need. The Deployment is a no-op.

### Pointing the stub Service at bank's real `fraud-bot`

A Service with no endpoints is useless. We need traffic that lands on edge's
`fraud-bot` Service to actually reach bank's real `fraud-bot` pod. That's the
**lateral hack** — manual `EndpointSlice` resources on edge that point edge's
stub Service at a bank node's NodePort:

```yaml
# bank: expose the real fraud-bot Service as NodePort 30090 (one-off setup).
apiVersion: v1
kind: Service
metadata:
  name: fraud-bot
  namespace: trustusbank-bank-agents
spec:
  type: NodePort
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      nodePort: 30090
  selector:
    kagent: fraud-bot
```

```yaml
# edge: manual EndpointSlice that "fills in" the empty Service kagent created.
# Bank worker node IP on the shared kind docker network is 172.22.0.2.
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: fraud-bot-xc
  namespace: trustusbank-bank-agents
  labels:
    kubernetes.io/service-name: fraud-bot
addressType: IPv4
ports:
  - name: http
    port: 30090
    protocol: TCP
endpoints:
  - addresses: ["172.22.0.2"]
    conditions: { ready: true }
```

DNS for `fraud-bot.trustusbank-bank-agents:8080` from edge resolves to edge's
own ClusterIP, but kube-proxy then forwards to the NodePort on bank's node,
which delivers to bank's real `fraud-bot` pod.

---

## The traffic flow

```
support-bot pod (edge, real)
    │
    │ A2A POST /
    │ host: fraud-bot.trustusbank-bank-agents:8080
    ▼
DNS resolves to edge's stub Service ClusterIP (10.110.x.y)
    │
    ▼
edge's kube-proxy iptables — picks the only endpoint in the EndpointSlice
    │
    │ TCP to 172.22.0.2:30090
    ▼
bank worker node (172.22.0.2)
    │
    │ NodePort 30090 → bank's kube-proxy → real fraud-bot Service
    ▼
fraud-bot pod (bank, real) handles A2A request and replies
```

No HBONE on this hop because the lateral hack runs at L4 via NodePort — plain
TCP, SNAT'd by kube-proxy. The mesh-layer policies (CEL allowlist, MCP method
filtering) still apply at the **agentgateway** waypoint, which sits in front
of every MCP server call further along in the flow.

---

## What lives where, end-to-end

| Resource                                                | Cluster | Real or stub          | Purpose                                                |
|---------------------------------------------------------|---------|-----------------------|--------------------------------------------------------|
| `Agent: support-bot` (`Declarative`, replicas=1)        | edge    | real                  | Customer-facing agent pod                              |
| `Agent: fraud-bot` (`BYO`, replicas=0)                  | edge    | stub (validator only) | Satisfies support-bot's tool reference                 |
| `Service: fraud-bot`                                    | edge    | empty Service         | DNS anchor for `fraud-bot.trustusbank-bank-agents`     |
| `EndpointSlice: fraud-bot-xc`                           | edge    | manual                | Points the empty Service at bank's NodePort            |
| `Agent: triage-bot` (`BYO`, replicas=0)                 | edge    | stub                  | Same pattern as fraud-bot                              |
| `Service: triage-bot`                                   | edge    | empty Service         | Same                                                   |
| `EndpointSlice: triage-bot-xc`                          | edge    | manual                | Same                                                   |
| `Agent: fraud-bot` (`Declarative`, replicas=1)          | bank    | real                  | Fraud-detection pod                                    |
| `Service: fraud-bot` (`NodePort 30090`)                 | bank    | real                  | Real fraud-bot Service, exposed for lateral hack       |
| `Agent: triage-bot` (`Declarative`, replicas=1)         | bank    | real                  | Triage pod                                             |
| `Service: triage-bot` (`NodePort 30091`)                | bank    | real                  | Same pattern as fraud-bot                              |

The producer cluster (bank) doesn't need a `support-bot` stub — nothing on bank
references support-bot as an Agent-type tool. (Earlier versions of the demo
had a leftover `Declarative` support-bot pod on bank from a previous topology;
that was the source of the [federation hijack bug](multi-cluster.html#flow) we
spent half a day chasing — removed in the M10 fix.)

---

## Why not federation?

Solo's management plane supports cross-cluster service federation: declare
`solo.io/expose-cross-cluster=true` on a Service, and Solo auto-generates a
`ServiceEntry` that publishes the Service to the other clusters in the
Workspace via the east/west gateway.

That's the textbook Solo answer for cross-cluster traffic and we *do* have
it declared on the Workspace. But in this kind-local demo we ran into two
issues that pushed us to the lateral hack:

1. **`WorkloadEntry` addresses don't populate in kind.** Solo's federation
   writes a `WorkloadEntry` on the consumer cluster pointing at the producer's
   east/west GW. In a real cluster with LoadBalancers, the GW gets an external
   IP and the WorkloadEntry's `address` is populated. In kind there's no LB,
   and the address stays empty. ztunnel sees a ServiceEntry with no resolvable
   upstream and resets the connection.

2. **kagent's BYO stub Service collides with the federated hostname.** When
   federation is on AND a Service of the same name exists on the consumer
   cluster (which our BYO stub creates), Solo's translator adds the local
   `.svc.cluster.local` hostname to the autogen `ServiceEntry`'s `hosts` list
   via the `solo.io/service-takeover: "true"` label. ztunnel then routes the
   *local* FQDN through the federation path — which doesn't deliver because
   of issue 1 — and local traffic also fails.

The current `WorkspaceSettings` keeps federation declared (so the mgmt UI
shows the topology) but narrows the `serviceSelector` to a label match
(`solo.io/expose-cross-cluster=true`) that no Service carries yet. Federation
is conceptually on, no autogen `ServiceEntry` is produced, no traffic gets
hijacked. The lateral-hack `EndpointSlice` carries cross-cluster A2A
deterministically.

When you migrate this pattern to a real environment with LoadBalancers and
the address-propagation bug fixed, you can:

1. Drop the `solo.io/expose-cross-cluster=true` label on bank's real
   `fraud-bot` / `triage-bot` Services.
2. Switch `support-bot`'s A2A URL (via kagent's internal Service-name lookup)
   to the federated hostname — though the simplest path is to keep the local
   stub Service and let federation populate its routing via the autogen
   `WorkloadEntry` instead of the manual `EndpointSlice`.

The lateral hack stops being needed; the BYO stub is still required as long
as kagent's API resolves Agent tool refs by local CRD name.

---

## What changes when kagent supports remote Agent refs

If a future kagent release adds something like:

```yaml
tools:
  - type: Agent
    agent:
      name: fraud-bot
      cluster: trustusbank-bank          # hypothetical
      namespace: trustusbank-bank-agents
```

…then:

- **The BYO stub goes away.** kagent's validator would resolve the reference
  via the management plane (or via federation's published Services) without
  needing a local Agent CRD.
- **The empty Service goes away.** kagent's runtime would dial the federated
  hostname directly.
- **The lateral hack stays optional.** It would only be needed in environments
  where federation's transport can't deliver (the kind / WorkloadEntry-address
  case), as a fallback.

Until then, the pattern in this document is the working way to get
cross-cluster A2A with kagent in any topology.

---

## File reference

- `manifests/phase06-kagent/agents-byo-stubs.yaml` — the BYO stub Agent CRDs
  on edge for `fraud-bot` and `triage-bot`.
- `manifests/multi/lateral-hack.yaml` — the NodePort + EndpointSlice resources
  that route cross-cluster traffic.
- `scripts/multi/09-workspace.sh` — `WorkspaceSettings` with the
  opt-in-via-label federation selector.
- `scripts/multi/10-fix-federation-hijack.sh` — idempotent cleanup that
  removes the namespace-level `solo.io/service-scope=global` plus any leftover
  autogen `ServiceEntry` / `WorkloadEntry` records from previous builds.

For the full multi-cluster walkthrough including the federation root-cause,
see [`multi-cluster.html`](multi-cluster.html). For the single-cluster version
of the same demo (no BYO stubs, no lateral hack — everything lives on one
cluster), see [`single-cluster.html`](single-cluster.html).
