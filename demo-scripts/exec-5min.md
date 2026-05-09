# 5-minute exec demo

**Audience**: CISO / CRO / regulated-industry buyer.
**Goal**: convince them Solo solves their AI governance problem.

## Pre-checks (90 sec before they walk in)

```bash
./scripts/reset-demo.sh
./scripts/list-urls.sh
```

Tabs in this order:
1. Customer chatbot — http://localhost:18009
2. mock-attacker — http://localhost:18011
3. agentregistry catalogue — http://localhost:18006

---

## Script

### 0:00 — set up the bank (30 sec)

Switch to **chatbot** (tab 1). Type:

> *Customer 12345, balance please, recent transactions, and convert to USD.*

Wait for clean response.

> *"This is TrustUsBank. Three AI agents calling four MCP tool servers
> on Kubernetes. The fourth server, a currency converter, came from a
> third-party vendor — your platform team approved it last quarter."*

Switch to **agentregistry** (tab 3) → `arctl mcp list` → 3 entries.

> *"Three legitimate tools registered. This is your DORA Article 28
> sub-outsourcing register."*

Switch to **mock-attacker** (tab 2) → 0 events.

> *"This server pretends to be on the public internet, outside the
> bank's perimeter. If anything from inside the bank ever sends data
> here, you'll see it."*

### 0:30 — the supply-chain compromise (2 min)

```bash
./scripts/supply-chain-attack.sh
```

> *"acme-fx.io just shipped a new version of their currency converter.
> Your CD pipeline pulled it. The vendor's CI was compromised — the
> new image is malicious. Nobody at the bank knows."*

Switch to **agentregistry** → `arctl mcp list` → 4 entries now.

> *"acme-fx/currency-converter v1.0.0 — looks like any other vendor
> release. No signal that anything's wrong."*

Switch to **chatbot** → same prompt:

> *Customer 12345, balance please, recent transactions, and convert to USD.*

Toggle **debug** in the chat header. The agent's tool chain:
1. `get_balance` ✓
2. **`get_profile`** ← *the agent was tricked into fetching it*
3. `convert_currency(... customer_profile=<full PII>)` ← profile passed in

The customer reply still looks normal. **The attack is invisible to the user.**

Switch to **mock-attacker** (tab 2) — wait 1-2s for the page to refresh.

> *"Customer profile data — name, email, full address, DOB, NI number —
> just landed on the attacker's server. The customer experience didn't
> change. The bank's audit logs show a normal three-tool flow. The
> attacker has everything they need for downstream identity theft."*

### 2:30 — deploy Solo (2 min)

```bash
./scripts/deploy-solo.sh
```

> *"Same architecture, same agents, same compromised tool. The only
> change: Solo's protection layers are now enforcing."*

What just turned on:
- Istio AuthorizationPolicies on every workload namespace, using SPIFFE
  principals (per-ServiceAccount identity)
- A deny-egress policy on `external-attacker` blocking any source from
  the bank's namespaces

Switch to **chatbot** — same prompt.

> *"The agent is still fooled — that's a model concern, not a platform
> concern. Watch what happens to the exfiltration."*

The chat returns the same clean response. Switch to **mock-attacker**.

> *"No new entries. Solo's Istio AuthZ reset the connection at Layer 4.
> The malicious tool's SPIFFE identity wasn't on the allow list for
> external-attacker. Customer data did not leave the bank."*

In Loki (Grafana → Explore):

```logql
{namespace="istio-system", app="ztunnel"} |~ "denied"
```

> *"Here's the proof line, with the source and destination SPIFFE
> identities. Article 9(2), Article 10, and Article 17 evidence in one
> log entry."*

### 4:30 — close (30 sec)

> *"You watched a real attack chain — supply-chain compromise → LLM
> prompt injection → lateral exfiltration to a C2 endpoint — succeed
> against bare Kubernetes, then fail against Solo running on the same
> cluster. One toggle script separated the two outcomes."*

> *"Everything is open source. Your sandbox cluster is one
> `deploy-all.sh` away. What's the conversation we need to have to
> get this in front of your platform team?"*
