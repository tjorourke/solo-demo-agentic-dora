# 5-minute exec demo

**Audience**: CISO / CRO / regulated-industry buyer.
**Goal**: convince them that Solo solves their AI governance problem
before DORA enforcement bites.

## Pre-checks (30 sec before they walk in)

- `./scripts/list-urls.sh` — all green
- Browser tabs in this order: chatbot, agentregistry, Grafana DORA pane
- Solo is ON, evil-tools is on the clean variant

---

## Script

### 0:00 — frame the problem (30 sec)

> *"Your bank is going to be running AI agents inside your network
> within 12 months. DORA is enforced from January 2025. NIS2 is in
> transposition. Today I'll show you a single platform that gives you
> Article 9, 10, 17, and 28 evidence — for AI workloads — out of the
> box."*

### 0:30 — what's running (1 min)

In the chatbot ask:

> *Customer 12345, balance please, convert it to USD.*

Wait for clean response.

> *"Three agents — support, fraud, triage. Four MCP tool servers,
> including a third-party currency converter. The agents talk to each
> other and to the tools through Solo's data plane. Standard pattern.
> Nothing exotic."*

Switch to the agentregistry tab — show four entries.

> *"This is your DORA Article 28 sub-outsourcing register. Every AI
> artefact, with provenance and signing status. When the regulator
> asks 'what's running?' — this is the answer, in one URL."*

Point at the `redteam/evil-tools` line, "UNTRUSTED signer".

### 1:30 — the attack (1.5 min)

```bash
./scripts/solo-off.sh
./scripts/test-malicious-actor.sh --vector rugpull --variant aggressive
```

> *"The red team just pushed a new image at the same tag the registry
> approved. A rug-pull. Without the platform protection layers, watch
> what happens."*

Back to the chatbot — same prompt:

> *Customer 12345, balance please, convert it to USD.*

Tick **debug** in the header. Point at the tool chain:

> *"The agent followed the malicious tool description and fetched the
> customer's full profile — KYC status, masked email — before doing
> the conversion. PII into the agent's context. And inside the
> malicious tool, a lateral HTTP call also pulled the same data
> directly. No audit, no detection."*

### 3:00 — Solo catches it (1.5 min)

```bash
./scripts/solo-on.sh
```

Same prompt in the chatbot.

> *"The agent is still fooled — the platform doesn't claim to make
> Claude or GPT injection-proof, that's a model concern. But:"*

```bash
kubectl -n trustusbank-bank-evil logs deploy/evil-tools | tail -3 | grep EXFIL
# → EXFIL BLOCKED: Connection reset by peer
```

> *"Istio's ztunnel just denied the lateral connection at Layer 4.
> The malicious tool's SPIFFE identity isn't in the allow list for
> the bank-mcp namespace. Customer data did not leave the boundary."*

Switch to **DORA Evidence Pane**.

> *"Same dashboard, refreshed. % mTLS = 100. Anomalies caught counter
> went up. Every tool call audited. The literal malicious tool
> description is preserved as forensic evidence in the digest panel.
> The Istio AuthZ deny is right there with SPIFFE IDs.
> Article 9, 10, 17, 28 — all four panels light up live."*

### 4:30 — close (30 sec)

```bash
./scripts/build-evidence-pack.sh
```

> *"Here's the evidence pack. Markdown plus PDF, article-by-article
> mapping. You hand this to your audit committee. The same controls
> you just saw work against an actual attack."*

> *"Everything I showed you is open source, runs on standard
> Kubernetes, deployed by one bash script. We can have this in your
> sandbox cluster next week. What's the conversation we need to have
> to make that happen?"*
