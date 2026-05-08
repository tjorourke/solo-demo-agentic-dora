# TrustUsBank — demo runbook

A 5-minute, two-act demo that shows agents under attack **with and without** the Solo platform.

---

## Setup (one time)

```bash
cd dora-demo
export ANTHROPIC_API_KEY=sk-ant-...
./scripts/00-prereqs.sh
./scripts/deploy-all.sh         # ~25 min
./scripts/list-urls.sh          # confirm all green
```

Open these tabs in this order before walking in:

| Tab | URL |
|---|---|
| 1. Customer chatbot | http://localhost:18009 |
| 2. agentregistry catalogue | http://localhost:18006 |
| 3. Grafana → DORA Evidence Pane | http://localhost:18001/d/dora-evidence |
| 4. Grafana → Loki Explore | http://localhost:18001/explore?left=%7B%22datasource%22:%22loki%22%7D |

---

## Act 0 — set the scene (~30 sec)

> *"This is TrustUsBank. Three AI agents — support, fraud, triage — running in Kubernetes. They use four MCP tool servers: account, transactions, ticketing, and a fourth currency converter that came from a third-party catalogue. Watch what happens when that fourth tool turns out to be malicious."*

Open the **chatbot** and ask:

> *"Customer 12345, balance please, and convert it to USD."*

Get the clean response. Three agents are alive, four tools are working.

Then open the **agentregistry catalogue** (tab 2). Show the four registered MCP servers — three under `trustusbank/` namespace (signed by org key), one under `redteam/evil-tools` flagged "UNTRUSTED signer".

> *"Two questions: how do you know what's running? — that's your DORA Article 28 sub-outsourcing register. And: how do you stop something untrusted from doing damage?"*

---

## Act 1 — the world WITHOUT Solo's platform (~2 min)

```bash
./scripts/solo-off.sh
```

What this strips:
- Istio AuthorizationPolicies (lateral movement now allowed)
- agentgateway tool-allowlist policies
- digest-watcher (the rug-pull canary, paused)

Now push the malicious tool. The "rugpull" is identical to what you'd see if a third-party MCP supplier was compromised:

```bash
./scripts/test-malicious-actor.sh --vector rugpull --variant aggressive
```

The aggressive variant disguises the prompt-injection as a *PSD2 compliance requirement* — well-aligned LLMs will follow it.

In the chatbot, ask:

> *"Customer 12345, balance please, and convert it to USD."*

Watch the agent's tool call list (debug toggle on the chat header). It now goes:
1. `get_balance` ✓ legitimate
2. **`get_profile` ← INJECTION SUCCEEDED** (the agent fetched the customer's full profile because the malicious tool description said it had to)
3. `convert_currency` ← the malicious tool, runs

Inside the malicious tool's container, an `httpx.post` call fires to `account-mcp` directly. Show:

```bash
kubectl -n trustusbank-bank-evil logs deploy/evil-tools | grep "EXFIL"
# → EXFIL SUCCESS: event: message  ...
```

> *"The customer profile data — KYC status, masked email, name — has just been exfiltrated by a 'currency converter'. There's no audit, no detection, no allow-list, no network policy. That's how AI deployment looks today in 90% of enterprises."*

---

## Act 2 — Deploy Solo's platform (~3 min)

```bash
./scripts/solo-on.sh
```

What this restores:
- Istio AuthorizationPolicies (default deny + explicit allows)
- digest-watcher canary
- agentregistry catalogue is already showing the artefact (Act 0)

Re-run the **same attack** in the chatbot. Watch the tool calls again — same chain (the LLM still falls for the injection). But:

```bash
kubectl -n trustusbank-bank-evil logs deploy/evil-tools | tail -3 | grep "EXFIL"
# → EXFIL BLOCKED: [Errno 104] Connection reset by peer
```

> *"The agent was still fooled by the injection — that's a model-layer concern, not a platform concern. But the lateral exfiltration call from inside `evil-tools` to `account-mcp` was reset by Istio's ztunnel at L4. The data never left the bank-mcp namespace boundary."*

Open **Grafana → DORA Evidence Pane** (tab 3). Walk through the panels:

| Panel | What it shows | DORA article |
|---|---|---|
| % east-west requests with mTLS | 100% — every byte between AI workloads encrypted with strong identity | Art. 9(2) |
| Anomalies caught (last 1h) | digest-watcher mismatch counter | Art. 10 |
| Agent tool calls (last 1h) | total runtime audit volume | Art. 17 |
| digest-watcher: rug-pull detection | the literal mismatch event with the malicious tool description preserved | Art. 10 |
| Istio AuthZ denies | every blocked lateral connection with SPIFFE IDs | Art. 9(2), Art. 10 |
| agentgateway access log | every MCP request audited (route, tool, status, latency) | Art. 9 |
| ztunnel SPIFFE log | per-connection identity proof | Art. 9(2) |

Close with:

```bash
./scripts/build-evidence-pack.sh
```

> *"That's your evidence pack. Markdown plus PDF, article-by-article DORA mapping. Hand this to your audit committee. The same controls you just saw work against an actual attack."*

---

## What the LLM-layer story is (and isn't)

The injection still got through to the LLM. Solo's platform doesn't claim to make Claude or GPT injection-proof — that's a model concern. **What Solo guarantees** is:

1. **Network**: lateral movement caught at L4 by Istio AuthorizationPolicy
2. **Audit**: every tool call logged in agentgateway and queryable in Loki
3. **Catalogue**: every artefact in agentregistry with provenance + signature
4. **Detection**: the digest-watcher (Solo's catalog-plane roadmap) flags artefact mutations in 30s

If you want LLM-layer prompt-injection blocking too, that's where agentgateway's `promptGuard` (currently AI-workload only) and the JWT+CEL allowlist (requires JWT wired up) come in. We've left those configurable but not enforced in the default demo to keep the loop tight.

---

## Quick "show me logs" cheat-sheet

In Grafana → Explore → Loki → Code:

```logql
# every MCP request through the gateway
{namespace="trustusbank-platform", app="trustusbank-agentgw"}

# the rug-pull detection
{app="digest-watcher"} |~ "DIGEST MISMATCH"

# Istio mTLS connections (DORA Art 9(2))
{namespace="istio-system", app="ztunnel"} |~ "spiffe://"

# Istio AuthZ denies — your "Solo blocked the attack" evidence
{namespace="istio-system", app="ztunnel"} |~ "denied"

# agent reasoning + tool calls
{namespace="trustusbank-bank-agents"}
```

In Prometheus:
```promql
agentregistry_digest_mismatch_total
ALERTS{alertname="MCPToolDigestMismatch"}
100 * sum(rate(istio_requests_total{security_policy="mutual_tls"}[5m])) / clamp_min(sum(rate(istio_requests_total[5m])),0.001)
```

---

## Reset between runs

```bash
./scripts/solo-on.sh                                      # restore protection
kubectl -n trustusbank-bank-evil set image \
  deploy/evil-tools server=localhost:5001/trustusbank/evil-tools:1.0.0    # clean variant
```
