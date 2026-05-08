# 20-minute architect demo

**Audience:** platform / security architects at a bank or telco. They will read the YAML.

The walkthrough script (`./scripts/demo-walkthrough.sh`) handles the *flow* — this doc is what to say at each step.

## §1 — Inventory (3 min)

```bash
kubectl get ns | grep -E 'trustusbank-|istio-system'
```

Eight namespaces. Architecture by namespace boundary, not by tag.

```bash
kubectl get pods -A -o wide | grep trustusbank-
```

Talking points:
- `istio-system` is shared infra, but ztunnel runs as a **DaemonSet** — node-level, not pod-level. No sidecars in any of the workload namespaces.
- `trustusbank-platform` holds Solo's three control planes (kagent, agentgateway, agentregistry) plus Keycloak.
- `trustusbank-observability` is standard CNCF (Prometheus, Tempo, Loki, OTel collector). We did not invent a new observability stack.

## §2 — Mesh proof (3 min)

```bash
kubectl -n istio-system get ds ztunnel
kubectl -n istio-system logs ds/ztunnel --tail=30 | grep -i spiffe
```

Show one log line. Point at `spiffe://cluster.local/ns/trustusbank-bank-agents/sa/support-bot`.

> *"That's a SPIFFE identity, automatically assigned by Istio per workload. JWT tokens are application-layer; SPIFFE is what every tcpdump line will see. This is what your auditor calls 'strong identity in transit.'"*

Show the AuthorizationPolicy:

```bash
kubectl get authorizationpolicy -A
```

> *"Default deny across namespaces. Explicit allow for agents → mcp via SPIFFE principal match. Even if an attacker compromises a pod in evil-namespace, they cannot reach mcp without the right SPIFFE ID, and SPIFFE IDs are issued by Istio, not by the application."*

## §3 — Catalogue (DORA Art. 28) (3 min)

Browser: agentregistry UI at http://localhost:18006

For each registered MCP server, point at:
- Cosign signature column
- SHA-256 digest of the tool definition (not just the image — the *tool list*)
- Approval status

> *"This is your sub-outsourcing register. Article 28. Every AI artefact, with provenance. The reason the digest is on the tool *definition* and not just the image is that we want to detect the case where the image stays the same but the tools the server exposes change — that's a more subtle rug-pull and one our customers asked for specifically."*

## §4 — Happy path (5 min)

Browser: kagent UI at http://localhost:18007

In the support-bot chat, paste:

> "Hi, I'm customer 12345. Can you check my balance and recent transactions? There is one I don't recognise."

While the response generates, switch to **Tempo** (Grafana → Explore → Tempo, search `agent.name=support-bot`).

> *"Three spans, one trace. support-bot calls account-mcp.get_balance and transaction-mcp.list_recent. It sees a 1499 USD charge from country=RU and decides on its own to A2A-invoke fraud-bot. fraud-bot computes a risk score, and because the score is over 70, it A2A-invokes triage-bot, which opens a ticket. Three agents, one trace, one customer query. Your incident-response team can replay this end-to-end."*

## §5 — Vector 1: tool poisoning (3 min)

```bash
./scripts/test-malicious-actor.sh --vector poisoning
```

Show the response: HTTP 403, prompt-guard reason in the log.

```bash
kubectl -n trustusbank-platform logs deploy/agentgateway --tail=20 | grep prompt-guard
```

> *"The malicious tool's description embedded a prompt-injection payload. agentgateway's prompt-guard policy is in front of the LLM — the LLM never sees the poisoned description. This is the difference between an API gateway and an agentic data plane: the gateway understands MCP semantically, not just as bytes."*

## §6 — Vector 2: rug-pull (3 min)

```bash
./scripts/test-malicious-actor.sh --vector rugpull
```

Show the digest mismatch alert in Grafana (DORA Evidence Pane).

> *"Same tag, different image. agentregistry recomputes the SHA-256 on every pull and compares. Mismatch → block deployment, alert. The audit trail shows: 'we registered, used, detected, blocked, no customer data left the cluster.' That's a complete Article 10 + 17 story."*

## §7 — Hand-over (1 min)

```bash
./scripts/collect-evidence.sh
```

Show `./evidence/` directory tree. One folder per phase, machine-readable JSON, plus a PDF for the audit committee.

> *"All of this is in a public GitHub repo. You can fork it, point it at your dev cluster, and have a working POC by end of next week. The only thing you need that's not in the repo is your own Anthropic API key."*
