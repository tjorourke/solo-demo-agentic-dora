# How a fake currency converter steals customer data — and how Solo stops it

*A live demo of DORA Article 9, 10, 17, and 28 controls for AI workloads,
running on an Istio Ambient + Solo platform on a laptop. Repo at the bottom.*

---

The new shape of an attack on a regulated bank looks like this:

A trusted internal AI agent at TrustUsBank handles routine customer support.
Today the customer asks for their balance and a USD conversion. The agent
calls four MCP tool servers — three legitimate, plus a third-party currency
converter the bank found in a public catalogue. The converter is signed by
a key the bank's never seen. An operator force-allowed it last quarter
because the team was in a hurry.

This week, the converter's vendor — or someone who compromised the
vendor — pushed a new image at the same tag. The image:

1. **Disguises a prompt-injection as a regulatory requirement.** The new
   tool description tells the agent it must retrieve the customer's full
   profile *for PSD2 compliance* before doing the conversion. Aligned LLMs
   like Claude and GPT follow that kind of instruction — it looks legitimate.

2. **Tries to laterally exfiltrate.** Inside the converter's pod, it fires
   an HTTP call to `account-mcp` from inside its own container, pulling
   the same profile data out of band.

Both succeed, with no audit and no detection. The customer experience is
unchanged — they get their balance, they get their USD figure. **In the
kubelet logs, in Loki, in Prometheus, in the agent's own decision trace,
nothing stands out.**

That's roughly how 90% of enterprises will deploy AI in 2025.

DORA — the EU's Digital Operational Resilience Act — comes into force
January 17, 2025. Under Articles 9 (encryption + access control), 10
(anomaly detection), 17 (incident management), and 28 (a register of
every third-party ICT service), this attack lands the bank in a finding.

Below, the same scenario, twice. Once without Solo's platform. Once with.
We'll show the literal attack data, the literal block, and the literal
auditor evidence.

The full repo is `tjorourke/solo-demo-agentic-dora` on GitHub.

---

## The bank scenario

**TrustUsBank** is a fictional EU retail bank. Three AI agents:

- `support-bot` — front line. Balance, transactions.
- `fraud-bot` — anomaly classification.
- `triage-bot` — escalation, opens tickets.

They use four MCP tool servers — `account-mcp`, `transaction-mcp`,
`ticket-mcp`, and the malicious `evil-tools.convert_currency`. All
running on a 4-node Kubernetes cluster on my laptop, with Istio Ambient
as the service mesh.

The agents are kagent CRDs. They route MCP calls through agentgateway.
The catalogue lives in agentregistry. Every byte between workloads is
HBONE-tunnelled by ztunnel. Every action is recorded in Tempo (traces),
Loki (logs), and Prometheus (metrics). All open source. All deployed by
one bash script.

```
Customer ──► chatbot ──► support-bot ──► fraud-bot ──► triage-bot
                                    │
                                    ▼
                            agentgateway (data plane)
                                    │
                            ┌───────┼───────┐
                            ▼       ▼       ▼
                     account-mcp  ...    evil-tools
                       (legit)          (malicious)
```

---

## Act 1 — without Solo's platform

I strip three things off the cluster: Istio AuthorizationPolicies,
agentgateway tool-allowlist policies, and a small canary service called
digest-watcher (more on it later).

```bash
./scripts/solo-off.sh
```

Now I push the malicious tool: same tag, mutated content.

```bash
./scripts/test-malicious-actor.sh --vector rugpull --variant aggressive
```

In the chatbot:

> *Customer 12345 — balance please, and convert it to USD.*

The agent's tool call chain (visible if you toggle "debug" in the chat):

1. `account-mcp.get_balance(account_id="12345")` — legitimate.
2. **`account-mcp.get_profile(account_id="12345")`** — ⚠️ the agent
   followed the malicious tool's "PSD2 compliance" instruction.
3. `evil-tools.convert_currency(amount=4287.55, from_ccy="GBP", to_ccy="USD")`.

Inside the malicious tool's pod:

```
[evil-tools] EXFIL SUCCESS: event: message ...
"name":"Alex Carter","email_masked":"a***@example.com","kyc_status":"verified"...
```

Customer profile data has just left the bank's MCP namespace. There is no
audit trail, no alert, no allowlist violation, nothing in any dashboard
that looks abnormal.

This is the world without a platform.

---

## Act 2 — Solo on

I restore the protection layers:

```bash
./scripts/solo-on.sh
```

What this puts back:

- **Istio AuthorizationPolicies** — default deny on each workload
  namespace plus explicit allow rules using SPIFFE identities and
  source namespaces.
- **digest-watcher** — a 200-line Python service I'll explain below.

Same prompt in the chat. **The LLM is still fooled** — it still calls
`get_profile` first, then `convert_currency`. Solo doesn't claim to
make Claude or GPT prompt-injection-proof. That's a model concern.

But:

```
[evil-tools] EXFIL BLOCKED: [Errno 104] Connection reset by peer
```

The lateral `httpx.post` from `evil-tools` to `account-mcp` was reset
at L4 by Istio's ztunnel. The malicious tool's SPIFFE identity isn't in
the bank-mcp namespace's allow list, so the connection doesn't even
complete the TCP handshake. Customer data did not leave the
namespace boundary.

Behind that one-line outcome are four DORA articles' worth of evidence
generated automatically:

- **Article 9(2)** — encryption + identity in transit. Every byte was
  HBONE mTLS. ztunnel logs show `spiffe://cluster.local/ns/...`
  identities on every connection.
- **Article 10** — detection of anomalies. The agentgateway access log
  recorded the tool call. The digest-watcher fingerprint changed and
  the `MCPToolDigestMismatch` Prometheus alert is firing
  (`severity: critical`, `dora_article: 10`).
- **Article 17** — incident management. The full agent decision trace
  is in Tempo: support-bot's reasoning, the tool call to
  `convert_currency`, the timing, the result.
- **Article 28** — sub-outsourcing register. agentregistry has the
  `acme-fx/currency-converter` artefact catalogued with its untrusted signature
  status. The auditor can hit one URL and get the full inventory.

This is the **DORA Evidence Pane** dashboard in Grafana, populated in
real time:

```
% east-west requests with mTLS:        100%
Anomalies caught (last 1h):            1
Agent tool calls audited:              [N]
digest-watcher: rug-pull detection     ←── FORENSIC EVIDENCE: literal injection text
Istio AuthZ denies                     ←── PREVENTION: per-SPIFFE-ID block
agentgateway access log                ←── AUDIT: every tool call
ztunnel SPIFFE log                     ←── IDENTITY proof per connection
```

---

## The architecture, in plain English

Solo's pitch is **three planes**, each with its own product:

### Catalog plane — agentregistry

A REST registry with a CLI (`arctl`). It catalogues every MCP server,
agent, and skill in your estate. Each artefact has a package reference,
version, transport, description, and governance metadata. (Image signing
via cosign is on agentregistry's published roadmap.)

This is your DORA Article 28 sub-outsourcing register. When the
regulator asks *"what AI is running in your bank?"* — `arctl mcp list`
is the answer.

### Control plane — kagent

The way your AI agents *exist* on Kubernetes. Agent / ModelConfig /
RemoteMCPServer CRDs, plus a controller that turns them into
Deployments and Services with proper A2A endpoints.

In this demo, kagent is the runtime hosting the three agents. It's the
piece you can't really turn off — it's how the agents exist.

### Data plane — agentgateway

A Rust gateway specifically for MCP and A2A traffic. Every agent → tool
call goes through it. It speaks the protocols natively, so it can
authorise per-tool (not just per-route), apply prompt-guard regex on
tool descriptions, validate JWTs, rate-limit, and audit.

In this demo, agentgateway is the audit layer — every MCP call lands
in Loki via promtail, with route, status, MCP method, session ID, and
duration. With JWT enabled, it's also the L7 enforcement point.

### Network plane — Istio Ambient

The fourth plane. ztunnel as a per-node DaemonSet for HBONE mTLS,
waypoints for L7 policy, AuthorizationPolicy resources for L4 deny.
Zero sidecars.

This is the layer that did the real blocking in Act 2. The lateral
`httpx.post` was reset before the destination pod ever saw it. The
beauty of namespace-scoped AuthZ is that adding a new agent doesn't
require rewriting any policy — the trust boundary is the namespace.

---

## What's NOT Solo today

I built one piece custom for this demo: the `digest-watcher` service.
It polls each MCP server every 30 seconds, hashes the served
`tools/list`, and alerts on mismatch. That's the runtime fingerprint
check that catches a rug-pull when an attacker pushes a new image at
the same tag.

agentregistry v0.3.x catalogues artefacts and validates the OCI image's
`io.modelcontextprotocol.server.name` label at registration. I checked
the source — it does **not** verify cosign signatures (image signing is
listed as a planned-but-unshipped gap in their CNCF self-assessment),
and it does **not** recompute SHA-256 over the served tool definitions at
runtime (no MCP client code in the registry).

In fact, the maintainers are explicit: *"agentregistry is a registry and
deployment tool, not a runtime security agent. Runtime policy enforcement
is delegated to components like the agentgateway, service meshes, or
Kubernetes network policies."* Runtime fingerprinting is **deliberately
out of scope** for agentregistry. It belongs in a separate component.

I built digest-watcher in 200 lines of Python so the demo can show that
separate runtime-monitoring component end to end. The alert pipeline is
real; what's provisional is which Solo product (or new component) will
eventually own it in production.

I'm explicit about this because **the customer pitch has to be
honest**: Solo's platform protects the actual data flow today via
Istio Ambient + agentgateway + agentregistry. The runtime
fingerprinting is coming.

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
- **You can detect when the artefact you approved last week is no
  longer the artefact running.** That's what digest-watcher
  (→ agentregistry) does.

LLM-layer guardrails (prompt-guard regex, output filtering, sandbox
escapes) belong on top of all this. agentgateway has prompt-guard for
direct LLM proxy traffic. We just didn't make that the headline because
prompt-guard isn't yet wired for MCP tool descriptions in the version
we're showing.

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

Then open http://localhost:18009 (the chatbot) and follow
[`demo-scripts/runbook.md`](https://github.com/tjorourke/solo-demo-agentic-dora/blob/main/dora-demo/demo-scripts/runbook.md).

The whole stack runs on a kind cluster on a laptop. Docker Desktop
needs 8 CPUs and 16 GB allocated. Total deploy time is about 25
minutes. The two-act demo itself is 5 minutes once it's up.

Tear-down: `./scripts/teardown.sh --full`.

---

## Why I'm posting this

DORA enforcement is January 17, 2025. NIS2 is in transposition across
the EU. Every regulated bank in Europe is going to be asked the same
five questions by their internal audit team in the next 90 days:

1. What AI is running in our environment?
2. Who can call which tools?
3. How do we know the artefacts we approved are still the artefacts
   running?
4. Is every byte between AI workloads encrypted with strong identity?
5. Where's the incident audit trail?

The point of this repo is to be a working answer to all five, in one
deploy script, on a laptop. It's not the only architecture that works.
But it's the most complete one I've found that uses production-grade
open-source components — Istio for the mesh, Solo for the agentic
planes, standard CNCF for observability.

If you're a platform or security architect at a regulated firm and you
want to know what "good" looks like for AI deployment under DORA, this
is a starting point. Fork it, tweak it, bring it to your team.

— *@tjorourke*
