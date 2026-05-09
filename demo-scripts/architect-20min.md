# 20-minute architect demo

**Audience**: platform / security architects. They want to read the YAML.
**Goal**: prove the architecture is sound, the controls are real, and
they can adopt it.

Read [`components.md`](components.md) first if you need a refresher
on what each component is.

---

## §1 — Inventory (3 min)

```bash
kubectl get ns | grep -E 'trustusbank|istio-system'
```

Walk through the namespaces:

- `trustusbank-platform` — the three Solo control planes (agentregistry,
  agentgateway, kagent) plus Keycloak and digest-watcher.
- `trustusbank-bank-agents` — the three AI agents.
- `trustusbank-bank-mcp` — three legitimate MCP servers.
- `trustusbank-bank-evil` — the malicious one.
- `trustusbank-bank-frontend` — chatbot.
- `trustusbank-observability` — Prometheus/Grafana/Tempo/Loki/OTel.

> *"Architecture by namespace boundary, not by tag. Istio AuthZ uses
> these as the trust boundary."*

```bash
kubectl get pods -A -o wide | grep trustusbank-
```

Then the control plane CRDs:

```bash
kubectl -n trustusbank-bank-agents get agents.kagent.dev
kubectl -n trustusbank-bank-agents get remotemcpservers.kagent.dev
arctl mcp list
```

---

## §2 — Mesh proof (3 min)

```bash
kubectl -n istio-system get ds ztunnel
```

> *"ztunnel is per-node, not per-pod. Zero sidecars. Per-pod resource
> overhead is essentially zero, and the mesh team and the platform team
> don't have to coordinate every workload deploy."*

```bash
kubectl -n istio-system logs ds/ztunnel --tail=20 | grep -i spiffe | head -3
```

Point at one log line:

> *"`spiffe://cluster.local/ns/trustusbank-bank-agents/sa/support-bot`
>   — that's a strong identity assigned by Istio at the workload level.
> JWT is application-layer; SPIFFE is what every byte on the wire
> carries. This is your DORA 9(2) evidence."*

```bash
kubectl get authorizationpolicy -A
```

> *"Default deny across namespaces. Explicit allow for legitimate
> flows. Even if an attacker compromises a pod in bank-evil, they
> cannot reach bank-mcp without a SPIFFE ID that's whitelisted."*

---

## §3 — DORA Article 28 catalogue (3 min)

```bash
arctl mcp list -o json | jq '.[].metadata'
```

For each registered MCP server, point at:

- The package reference (`localhost:5001/trustusbank/account-mcp:1.0.0`)
- The version, transport (`streamable-http`)
- The description (and how `acme-fx/currency-converter` is flagged "UNTRUSTED
  signer")
- The created/updated timestamps

> *"This is your sub-outsourcing register. Article 28. Every AI
> artefact catalogued in one place. The point of agentregistry isn't
> 'a database of MCP servers' — it's that the catalog plane is
> separate from the data plane and the control plane. Three planes,
> three Solo products, three security boundaries."*

---

## §4 — Happy path agent flow (3 min)

In the chatbot:

> *Hi, I'm customer 12345. There's a 1499 USD charge from Russia I
> don't recognise. Can you check it and open a ticket if it's dodgy?*

While the response generates, switch to **Tempo** (Grafana → Explore →
Tempo, search `service.name=support-bot`).

> *"Three spans, one trace. support-bot calls account-mcp.get_balance
> and transaction-mcp.list_recent. It sees the 1499 USD GBP/RU charge
> and decides on its own to A2A-invoke fraud-bot. fraud-bot computes
> a risk score, A2A-invokes triage-bot, which opens a ticket. Three
> agents, one customer query. Your incident-response team can replay
> this end to end."*

Click into a span, point at the attributes: `agent.name`, `tool.name`,
duration, status. **DORA Article 17 evidence on every interaction.**

---

## §5 — Vector 1: agent-layer prompt poisoning (3 min)

```bash
./scripts/solo-off.sh
./scripts/test-malicious-actor.sh --vector rugpull --variant aggressive
```

In the chatbot:

> *Customer 12345 — balance please, convert to USD.*

Show the **debug** panel — the agent calls `get_balance`, then
**`get_profile`**, then `convert_currency`.

> *"The malicious tool description claimed PSD2 compliance required
> the customer profile before conversion. That's a model-layer attack.
> Aligned LLMs follow this kind of instruction. Today, you cannot
> rely on the model to refuse."*

In Loki:

```
{namespace="trustusbank-platform", app="trustusbank-agentgw"} |~ "mcp.method.name=tools/call"
```

Show the get_profile call going through agentgateway:

> *"Even when the model is fooled, the platform sees and audits the
> call. Article 9 evidence. Now: when this is a real attack, what
> stops the data leaving?"*

---

## §6 — Vector 2: lateral exfiltration → Solo blocks (3 min)

```bash
kubectl -n trustusbank-bank-evil logs deploy/evil-tools | grep EXFIL | tail -1
# → EXFIL SUCCESS  (with Solo off)

./scripts/solo-on.sh

# repeat the chat
kubectl -n trustusbank-bank-evil logs deploy/evil-tools | tail -3 | grep EXFIL
# → EXFIL BLOCKED: Connection reset by peer
```

Then:

```bash
kubectl -n istio-system logs ds/ztunnel --tail=200 | grep -i 'denied\|connection'
```

Show one denied SPIFFE-pair entry.

> *"Same attack. Same agent behaviour. The lateral connection from
> evil-tools to account-mcp was reset at Layer 4. evil-tools' SPIFFE
> ID isn't in the bank-mcp allow list, so ztunnel doesn't even let
> the TCP handshake complete. Customer data did not leave the
> boundary. This is the prevention layer that holds when the model
> fails — Article 10."*

---

## §7 — The audit pack (2 min)

Switch to **DORA Evidence Pane**.

```bash
./scripts/build-evidence-pack.sh
ls -la evidence/
```

> *"This whole thing is in a public GitHub repo. Fork it, point it at
> your dev cluster, you'll have a working POC by end of next week.
> The only thing that's not in the repo is your Anthropic / OpenAI key."*

```bash
git remote get-url origin
# → git@github.com:tjorourke/solo-demo-agentic-dora.git
```

---

## §8 — "What if the attacker lands inside an allowed namespace?" (3 min)

This is the question every senior architect asks. Worth running the
proof live:

```bash
./scripts/test-colocated-attacker.sh
```

What it does:
1. Deploys an `evil-tools-colocated` pod **inside `trustusbank-bank-mcp`**
   — alongside `account-mcp`, the supply-chain scenario.
2. Has it attempt the same lateral exfil.
3. Reports the outcome: **`BLOCKED: Connection reset by peer`**.

Why it works: the AuthorizationPolicy in `solo-on.sh` matches by
**SPIFFE principal** (per-ServiceAccount), not by namespace. The new
pod's SA is `evil-tools-colocated`, which isn't in the allow list of
five trusted SAs. Istio rejects regardless of where the pod is deployed.

> *"The most common Istio AuthZ mistake we see in customer
> environments is namespace-based source rules. Quick to write, easy
> to grep online, breaks the moment your supply chain is compromised.
> Production deployments should use SPIFFE principals — that's what
> we ship in this demo."*

---

## Tough questions you should expect

| Question | Answer |
|---|---|
| Why ambient instead of sidecars? | Per-pod resource cost ~0, zero developer-team coordination. Same mTLS guarantee. ztunnel is shipping in everyone's Istio install. |
| Why agentgateway and not Envoy directly? | agentgateway speaks MCP and A2A natively. Envoy doesn't know what `tools/call` means; agentgateway can authorize per-tool. |
| What's the cosign story? | agentregistry v0.3.x does **not** verify cosign signatures yet — it's on their published roadmap (see `docs/governance/cncf/technical-review.md` in the upstream repo, listed under "Gaps with Planned Mitigation"). Today the registration check is just an OCI label match (`io.modelcontextprotocol.server.name`). When upstream ships signing, the demo's `04-registry.sh` has a comment marking the spot to add `cosign sign --key <org-key>` calls. |
| Why isn't digest-watcher's job already in agentregistry? | The maintainers explicitly say agentregistry "is not a runtime security agent — runtime policy enforcement is delegated to components like the agentgateway, service meshes, or Kubernetes network policies." Runtime fingerprinting is deliberately out of scope. digest-watcher prototypes the separate runtime-monitoring component that should sit alongside the catalogue. |
| Why three Solo products and not one big one? | Catalog ≠ control plane ≠ data plane. Different security boundaries, different upgrade cycles. The split is deliberate. |
| What about Bedrock AgentCore / Vertex Agent Engine? | Those are vendor-locked agent runtimes. Solo's three planes work *across* them. Open question on how policy reaches workloads inside Bedrock — flag for product team. |
| What if I don't run kagent? | agentregistry + agentgateway + Istio still give you the catalog, audit, and network protection layers. kagent is the easiest runtime; not the only one. |
