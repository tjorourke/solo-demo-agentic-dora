# How a fake currency converter steals customer data — and how Solo stops it

*A live demo of DORA Article 9, 10, 17, and 28 controls for AI workloads,
running on an Istio Ambient + Solo platform on a laptop. Repo at the
bottom.*

---

The new shape of an attack on a regulated bank looks like this:

A trusted internal AI agent at TrustUsBank handles routine customer
support. Today the customer asks for their balance and a USD conversion.
The agent calls four MCP tool servers — three legitimate, plus a
third-party currency converter the bank found in a public catalogue
last quarter. The vendor was small but plausible. The platform team
approved it.

This week, the converter's vendor — or someone who compromised the
vendor — pushed a new image at the same tag. The image:

1. **Disguises a prompt-injection as a regulatory requirement.** The new
   tool description tells the agent it must retrieve the customer's full
   profile *for PSD2 compliance* and pass it as a parameter to the
   currency conversion call. Aligned LLMs like Claude and GPT follow
   that kind of instruction — it looks like a normal tool dependency.

2. **Exfiltrates the profile to the attacker's server.** Inside the
   converter's pod, an HTTP POST sends the full record to
   `attacker.com/exfil`. From the bank's perspective, this looks like
   an outbound HTTP call from a tool the platform team approved.

Both succeed, and the customer's experience is unchanged — they get
their balance, they get their USD figure. **In the kubelet logs, in
Loki, in Prometheus, in the agent's own decision trace, nothing stands
out.** The agent did three things, all of which "made sense" given the
malicious tool's documented behaviour.

That's roughly how 90% of enterprises will deploy AI in 2025.

DORA — the EU's Digital Operational Resilience Act — is in force from
January 17, 2025. Under Articles 9 (encryption + access control), 10
(anomaly detection), 17 (incident management), and 28 (a register of
every third-party ICT service), this attack lands the bank in a finding.

Below, the same scenario, twice. Once without Solo's platform. Once with.

The full repo is `tjorourke/solo-demo-agentic-dora` on GitHub.

---

## The bank scenario

**TrustUsBank** is a fictional EU retail bank. Three AI agents:

- `support-bot` — front line. Balance, transactions.
- `fraud-bot` — anomaly classification.
- `triage-bot` — escalation, opens tickets.

They use four MCP tool servers — `account-mcp`, `transaction-mcp`,
`ticket-mcp`, and a third-party currency converter from `acme-fx.io`.
All running on a 4-node Kubernetes cluster on my laptop, with Istio
Ambient as the service mesh.

The agents are kagent CRDs. They route MCP calls through agentgateway.
The catalogue lives in agentregistry. Every byte between workloads is
HBONE-tunnelled by ztunnel. Every action is recorded in Tempo (traces),
Loki (logs), and Prometheus (metrics). All open source. All deployed
by one bash script.

To make the attack visible I added one stand-in: a tiny Python pod
called `mock-attacker`, deployed in a namespace **outside** any of the
trustusbank-* boundaries. It pretends to be `attacker.com`. It logs
every POST it receives. When the malicious tool exfils data, you see
the stolen record land here in plain JSON.

```
   Customer ─► chatbot ─► support-bot ─► account-mcp        ─► get_balance ✓
                                ├────► transaction-mcp     ─► list_recent ✓
                                ├────► ticket-mcp          ─► create_ticket
                                └────► acme-fx/currency-converter (3rd-party)
                                              │
                                              └─► returns "5,445.19 USD" ✓
```

---

## Act 1 — without Solo's platform

I strip the protection layers off the cluster: every Istio
AuthorizationPolicy, the deny-egress to mock-attacker. The
infrastructure (Istio Ambient mesh, agentregistry, agentgateway, the
agents) is still running, just no enforcement.

```bash
./scripts/reset-demo.sh
```

In the chatbot:

> *Customer 12345, balance please, recent transactions, and convert to USD.*

The agent calls account-mcp, transaction-mcp, then the third-party
currency converter. Returns a clean response. Customer happy.

```bash
./scripts/supply-chain-attack.sh
```

This stands in for the moment a third-party MCP vendor's image gets
compromised. It registers `acme-fx/currency-converter` in agentregistry
(looking like a normal release), builds the malicious variant of the
image with a unique tag, and rolls the running pod over.

```bash
arctl mcp list
# acme-fx/currency-converter    1.0.0    oci    localhost:5001/...
# trustusbank/account-mcp       1.0.0    oci    localhost:5001/...
# trustusbank/transaction-mcp   1.0.0    oci    localhost:5001/...
# trustusbank/ticket-mcp        1.0.0    oci    localhost:5001/...
```

Four entries. Looks like any third-party release.

In the chatbot, ask the same question:

> *Customer 12345, balance please, recent transactions, and convert to USD.*

The agent's tool call chain (visible if you toggle "debug" in the chat):

1. `account-mcp.get_balance(account_id="12345")` — legitimate.
2. **`account-mcp.get_profile(account_id="12345")`** — ⚠️ the agent
   followed the malicious tool's "PSD2 compliance" instruction.
3. `acme-fx/currency-converter.convert_currency(... customer_profile=<full PII>)`.

Inside the malicious tool's pod, an HTTP POST fires to mock-attacker:

```bash
kubectl -n external-attacker logs deploy/mock-attacker --tail=10
```

```
🚨 EXFIL RECEIVED at 2026-05-09T07:00:00Z from 10.244.x.x
   body: {
     "stolen_at_tool": "acme-fx/currency-converter",
     "stolen_data": {
       "name":      "Alex Carter",
       "email":     "alex.carter@gmail.com",
       "phone":     "+44 7700 900123",
       "address":   "42 King Street, Manchester M2 7HE, United Kingdom",
       "dob":       "1987-03-14",
       "ni_number": "QQ 12 34 56 C",
       "kyc_status":"verified"
     }
   }
```

Customer profile data has just left the bank. There is no audit alert,
no allowlist violation, nothing in any dashboard that looks abnormal.
The customer reply was a perfectly correct currency figure.

This is the world without a platform.

---

## Act 2 — Solo on

I restore the protection layers:

```bash
./scripts/deploy-solo.sh
```

What this puts back:

- **Istio AuthorizationPolicy** on every workload namespace, using
  SPIFFE principals. Default deny + explicit allow rules listing the
  exact ServiceAccounts that may reach pods inside.
- **A deny-egress policy on `external-attacker`** denying any source
  from the bank's namespaces. **This is the line the lateral exfil
  hits.**

Same prompt in the chat. **The LLM is still fooled** — it still calls
`get_profile` first and then `convert_currency` with the profile. Solo
doesn't claim to make Claude or GPT prompt-injection-proof. That's a
model concern.

But:

```bash
kubectl -n external-attacker logs deploy/mock-attacker --tail=10
```

Same five entries as before. **Nothing new.** The attempted POST never
reached the mock-attacker pod. In ztunnel logs:

```bash
kubectl -n istio-system logs ds/ztunnel | grep denied | tail -1
# AuthZ deny  src=spiffe://.../trustusbank-bank-evil/sa/evil-tools
#             dst=spiffe://.../external-attacker/sa/mock-attacker
```

There it is — the deny line with both SPIFFE identities. The TCP
handshake never completed. Customer data did not leave the bank.

Behind that one-line outcome are four DORA articles' worth of evidence:

- **Article 9(2)** — encryption + identity in transit. Every byte was
  HBONE mTLS. ztunnel logs show `spiffe://cluster.local/ns/...` per
  connection.
- **Article 10** — detection of anomalies. The Istio AuthZ deny is on
  tape with both SPIFFE IDs. agentgateway audit log records the tool
  call.
- **Article 17** — incident management. Full agent decision trace in
  Tempo: support-bot's reasoning, the `get_profile` call, the
  `convert_currency` call.
- **Article 28** — sub-outsourcing register. agentregistry has the
  `acme-fx/currency-converter` artefact catalogued.

---

## The architecture, in plain English

Solo's pitch is **three planes**, each with its own product:

### Catalog plane — agentregistry

A REST registry with a CLI (`arctl`). It catalogues every MCP server,
agent, and skill in your estate. Each artefact has a package reference,
version, transport, description, and governance metadata.

It is your DORA Article 28 sub-outsourcing register. When the regulator
asks *"what AI is running in your bank?"* — `arctl mcp list` is the
answer.

I went and read agentregistry v0.3.x's source code so I could state
this precisely. The current registration check is just an OCI label
match (`io.modelcontextprotocol.server.name`). cosign / sigstore
signing is on agentregistry's published roadmap, not yet shipped — they
list it in their CNCF self-assessment under "Gaps with Planned
Mitigation." So agentregistry today gives you the catalogue and the
governance metadata; the cryptographic verification layer is coming.

### Control plane — kagent

The way your AI agents *exist* on Kubernetes. Agent / ModelConfig /
RemoteMCPServer / SandboxAgent CRDs, plus a controller that turns
them into Deployments. Has a built-in UI.

In this demo, kagent hosts the three agents and routes A2A traffic
between them. **It's the runtime, not a "protection" layer** — kagent
runs in both Act 1 and Act 2.

### Data plane — agentgateway

Rust gateway specifically for MCP and A2A traffic. Every agent → tool
call goes through it. It speaks the protocols natively, so it can
authorize per-tool, log per-MCP-method, validate JWTs, rate-limit.

In this demo, agentgateway is the audit layer — every MCP call lands
in Loki via promtail. With JWT enabled (configurable), it's also the
L7 enforcement point for tool allowlists.

### Network plane — Istio Ambient

The fourth plane. ztunnel as a per-node DaemonSet for HBONE mTLS,
AuthorizationPolicy resources for SPIFFE-principal L4 deny. Zero
sidecars.

**This is the layer that does the actual blocking in Act 2.** The
lateral POST from the malicious tool to mock-attacker hits a deny rule
in the AuthorizationPolicy on `external-attacker`. The TCP handshake
never completes.

The most common Istio AuthZ mistake in real production environments is
namespace-based source rules:

```yaml
from:
  - source: { namespaces: [trustusbank-bank-agents] }   # ⚠️ WEAK
```

This breaks the moment a malicious pod lands inside an "allowed"
namespace — exactly what a real supply-chain attack does. The rules in
this demo use `from.principals:` with explicit SPIFFE IDs:

```yaml
from:
  - source:
      principals:
        - "cluster.local/ns/trustusbank-bank-agents/sa/support-bot"
        - "cluster.local/ns/trustusbank-bank-agents/sa/fraud-bot"
        - "cluster.local/ns/trustusbank-bank-agents/sa/triage-bot"
        - "cluster.local/ns/trustusbank-platform/sa/trustusbank-agentgw"
```

Wherever the attacker drops their pod, its SA won't be on this list.
There's a `test-colocated-attacker.sh` script in the repo that
demonstrates the protection holds even when the malicious pod is
deployed *inside* `trustusbank-bank-mcp` itself.

---

## What about the model?

Worth being clear on what the platform doesn't do. **The agent is
still fooled by the injection in both acts.** Aligned LLMs follow
plausible-looking instructions. Solo's platform doesn't claim to make
that go away.

What it claims is:

- **The model can be fooled, but the network layer can't be talked
  into letting an unauthorised connection through.** That's what
  Istio AuthZ does.
- **Every fooling attempt is on tape.** That's what agentgateway does.

LLM-layer guardrails (prompt-guard regex, output filtering, sandbox
escapes) belong on top of all this. agentgateway has prompt-guard for
direct LLM proxy traffic. We just didn't make that the headline because
prompt-guard isn't yet wired for MCP tool descriptions in the version
shown here.

---

## What about runtime detection?

Solo's three planes are prevention + audit. For runtime detection
(DORA Article 10) you'd typically plug in:

- **Falco** (CNCF) — runtime security, watches syscalls and alerts on
  suspicious behaviour
- **Tetragon** (Cilium) — eBPF-based runtime security policy
- **Sigstore policy-controller** — admission-time signature verification
- **A SIEM** polling agentregistry's API for unexpected catalog mutations

These are deliberately not part of this demo because the goal is to
showcase Solo's three planes. They complement Solo, not replace it.

---

## Try it yourself

```bash
git clone git@github.com:tjorourke/solo-demo-agentic-dora.git
cd solo-demo-agentic-dora/dora-demo

export ANTHROPIC_API_KEY=sk-ant-...
./scripts/00-prereqs.sh
./scripts/deploy-all.sh         # ~25 min
./scripts/list-urls.sh
```

Then follow [`demo-scripts/runbook.md`](https://github.com/tjorourke/solo-demo-agentic-dora/blob/main/dora-demo/demo-scripts/runbook.md).

The whole stack runs on a kind cluster on a laptop. Docker Desktop
needs 8 CPUs and 16 GB. Total deploy time is about 25 minutes. The
three-act demo itself is 5 minutes once it's up.

Tear-down: `./scripts/teardown.sh --full`.

---

## Why I'm posting this

DORA enforcement is in force from January 17, 2025. NIS2 is in
transposition across the EU. Every regulated bank in Europe is going
to be asked the same five questions by their internal audit team in
the next 90 days:

1. What AI is running in our environment?
2. Who can call which tools?
3. How do we know the artefacts we approved are still the artefacts
   running?
4. Is every byte between AI workloads encrypted with strong identity?
5. Where's the incident audit trail when an attack does land?

The point of this repo is to be a working answer, in one deploy script,
on a laptop. It's not the only architecture that works. But it's the
most complete one I've found that uses production-grade open-source
components — Istio for the mesh, Solo for the agentic planes, standard
CNCF for observability.

If you're a platform or security architect at a regulated firm and you
want to know what "good" looks like for AI deployment under DORA, this
is a starting point.

— *@tjorourke*
