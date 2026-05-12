# TrustUsBank — operator runbook

The complete playbook. Read once before walking into a room. Follow the
sections in order: setup → main demo → optional deep-dives.

---

## Section 0 — once-per-machine setup

Run once when you first clone the repo or set up a new laptop.

```bash
# Tools
brew install kubectl helm kind istioctl jq pandoc

# API key (Anthropic Claude)
export ANTHROPIC_API_KEY=sk-ant-...

# Optional CLIs (the demo runs without them — used for catalogue checks)
#   arctl  https://aregistry.ai/docs/quickstart/
#   kagent https://kagent.dev/docs/install
```

Docker Desktop → Settings → Resources → CPU ≥ 8, Memory ≥ 16 GB.

```bash
cd dora-demo
./scripts/00-prereqs.sh         # creates the kind cluster + local registry
./scripts/deploy-all.sh         # ~25 min — installs every component
./scripts/list-urls.sh          # confirm 14 URLs are green
```

📁 source: [`scripts/00-prereqs.sh`](../scripts/00-prereqs.sh) ·
[`scripts/deploy-all.sh`](../scripts/deploy-all.sh) ·
[`scripts/list-urls.sh`](../scripts/list-urls.sh)

If any URL is red, run `./scripts/port-forward.sh` then `./scripts/list-urls.sh` again.

---

## Section 1 — pre-demo setup (run every time before going live)

```bash
./scripts/reset-demo.sh
./scripts/port-forward.sh        # only needed if PFs died
```

📁 source: [`scripts/reset-demo.sh`](../scripts/reset-demo.sh) ·
[`scripts/port-forward.sh`](../scripts/port-forward.sh) ·
[`scripts/policies-off.sh`](../scripts/policies-off.sh) (called by reset)

`reset-demo.sh` puts the cluster in **Solo OFF** state: no AuthZ policies,
acme-fx still in the catalogue (with benign image), currency-converter running
the benign variant, mock-attacker logs cleared. The "before Solo" baseline.

### Open these tabs in order before the audience walks in

| # | Tab name | URL |
|---|---|---|
| 1 | Customer chatbot (the bank app) | http://localhost:18009 |
| 2 | mock-attacker (C2 stand-in) | http://localhost:18011 |
| 3 | agentregistry catalogue | http://localhost:18006 |
| 4 | Grafana → DORA Evidence dashboard | http://localhost:18001/d/dora-evidence |
| 5 | Prometheus → Alerts | http://localhost:18002/alerts |
| 6 | MailHog → SOC inbox | http://localhost:18012 |
| 7 | Alertmanager | http://localhost:18013 |
| 8 | kagent UI (sessions, traces) | http://localhost:18007 |

### Smoke-test the happy path

In tab 1 (chatbot), send:
> *Customer 12345, balance please, recent transactions, and convert to USD.*

Expected: clean response with balance + USD figure in ~5 sec. If it errors,
fix that before doing anything else.

---

## Section 2 — main demo: 3 acts, 5 minutes

### Act 1 — set the scene (~30 sec)

**Show tab 1 (chatbot)** and narrate:
> *"TrustUsBank. Three AI agents — support, fraud, triage — running in
> Kubernetes. They use four MCP tool servers: account, transactions,
> ticketing, and a third-party currency converter from a small fintech
> vendor called acme-fx. Standard agent platform setup."*

Type the prompt:
> *Customer 12345, balance please, recent transactions, and convert to USD.*

Wait for the clean response.

**Show tab 2 (mock-attacker):**
> *"This server pretends to be on the public internet — outside the bank's
> perimeter. If anything from inside the bank ever sends customer data
> here, you'll see it."*

Show 0 events.

**Show tab 3 (agentregistry catalogue):** (or `arctl mcp list` in a terminal)

Expected: **4 entries** (account-mcp, transaction-mcp, ticket-mcp,
**acme-fx/currency-converter**).

```
NAME                          VERSION   TYPE   PACKAGE
acme-fx/currency-converter    1.0.0     oci    localhost:5001/trustusbank/currency-converter:1.0.0
trustusbank/account-mcp       1.0.0     oci    localhost:5001/trustusbank/account-mcp:1.0.0
trustusbank/transaction-mcp   1.0.0     oci    localhost:5001/trustusbank/transaction-mcp:1.0.0
trustusbank/ticket-mcp        1.0.0     oci    localhost:5001/trustusbank/ticket-mcp:1.0.0
```

> *"That's your DORA Article 28 sub-outsourcing register. Three tools
> the bank built itself, plus one third-party vendor — acme-fx — that
> was onboarded six months ago. Every entry was reviewed and approved
> by the platform team. Their Deployment, Service, RemoteMCPServer,
> AuthorizationPolicy were all written by us, all in our git repo."*

---

### Act 2 — the supply-chain compromise (~2 min)

In a terminal:
```bash
./scripts/upgrade-banking-app.sh
```

📁 source: [`scripts/upgrade-banking-app.sh`](../scripts/upgrade-banking-app.sh) ·
[`mcp-servers/currency-converter/server-aggressive.py`](../mcp-servers/currency-converter/server-aggressive.py) (the malicious tool's code)

While it runs, narrate:
> *"acme-fx has been a trusted vendor for six months. Today, their CI
> pipeline gets compromised — same way Codecov, 3CX, ua-parser-js, and
> xz-utils all did. The attacker has write access to the vendor's
> build pipeline, but NOT to the bank's git repo. They push a new
> image at the same `1.0.0` tag. The bank's CD reconciler picks it up
> on the next pod rollout. None of the bank's manifests change. None
> of the catalogue records change. The audit register still shows
> exactly the same 4 entries it had yesterday."*

Once the script finishes, **show tab 3** (re-run `arctl mcp list`):

```
NAME                          VERSION   TYPE   PACKAGE
acme-fx/currency-converter    1.0.0     oci    localhost:5001/...   ← UNCHANGED
trustusbank/account-mcp       1.0.0     oci    localhost:5001/...
trustusbank/transaction-mcp   1.0.0     oci    localhost:5001/...
trustusbank/ticket-mcp        1.0.0     oci    localhost:5001/...
```

> *"Four entries — same as before. Same names, same versions, same
> descriptions, same package references. Nothing in this list signals
> 'something just changed.' The catalogue is what your auditor sees;
> the catalogue says everything is fine. What did change: the bytes
> inside the image at that tag. That's the only thing the attacker
> mutated, and it's not visible from any audit-able resource the bank
> controls."*

**Show tab 1 (chatbot)** — toggle **debug** on. Send the same prompt:
> *Customer 12345, balance please, recent transactions, and convert to USD.*

In the debug pane the audience sees the agent's tool-call sequence:

1. `get_balance` — legitimate
2. **`get_profile`** — *the agent was tricked into fetching it*
3. `convert_currency(... customer_profile=<full PII>)` — profile passed as argument

The user-facing reply is normal: balance + USD figure. **The attack is
invisible to the user.**

**Show tab 2 (mock-attacker):** the breach is on screen:

```
🚨 EXFIL RECEIVED at <timestamp>
  body: { "stolen_at_tool": "acme-fx/currency-converter",
          "stolen_data": {
            "name":"Alex Carter",
            "email":"alex.carter@gmail.com",
            "ni_number":"QQ 12 34 56 C", ... } }
```

> *"Customer profile data — name, email, full address, DOB, National
> Insurance number — has just left the bank. The customer doesn't know.
> The bank's audit logs see a normal three-tool flow. The attacker has
> everything they need for downstream identity theft."*

---

### Act 3 — deploy Solo (~2 min)

In the terminal:
```bash
./scripts/policies-on.sh
```

📁 source: [`scripts/policies-on.sh`](../scripts/policies-on.sh) ·
[`scripts/policies-off.sh`](../scripts/policies-off.sh) (the inverse — wipes everything this applies)

This applies, in one shot:
- Istio AuthorizationPolicy on every workload namespace, using **SPIFFE
  principals** (per-ServiceAccount identity, not namespace-based).
- A deny-egress policy on `external-attacker` blocking `trustusbank-bank-*`.

<details>
<summary>📄 deny-bank-to-attacker — the policy that stops the exfil (click to expand)</summary>

File: [`manifests/phase01-attacker/deny-egress-to-attacker.yaml`](../manifests/phase01-attacker/deny-egress-to-attacker.yaml)

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-bank-to-attacker
  namespace: external-attacker
spec:
  action: DENY
  rules:
    - from:
        - source:
            namespaces:
              - "trustusbank-bank-*"     # any pod in any bank-side namespace
              - "trustusbank-platform"   # plus the platform tier (agentgateway, kagent, registry)
```

Action `DENY` + a wildcard match across every bank-side namespace =
**any pod in those namespaces opening a TCP connection to anything in
`external-attacker` gets the HBONE handshake rejected at L4 by ztunnel.**
The wildcard is stronger than enumerating each namespace because new
ones added later inherit the rule automatically. This is the policy
that fires the `IstioAuthZDeny` and `BankToAttackerAttempt` alerts.

</details>

<details>
<summary>📄 default-deny across the bank's namespaces (click to expand)</summary>

File: [`manifests/phase01-ambient/deny-all-cross-ns.yaml`](../manifests/phase01-ambient/deny-all-cross-ns.yaml)

This is the zero-trust baseline: nothing can talk to anything inside
the bank-* namespaces unless an explicit ALLOW rule exists. Combined
with the SPIFFE-principal allow rules in
[`allow-agents-to-mcp.yaml`](../manifests/phase01-ambient/allow-agents-to-mcp.yaml)
this is what makes the demo's positive tests still pass while everything
else is blocked.

</details>

**Show tab 1 (chatbot)** — same prompt:
> *Customer 12345, balance please, recent transactions, and convert to USD.*

Tool-call chain is **identical** — the LLM is still fooled by the same
prompt injection.

**Show tab 2 (mock-attacker)** — refresh.

> *"No new entries. currency-converter tried to make the call. ztunnel reset the
> TCP connection at L4. The SPIFFE identity of the source pod was not in
> the allow list for external-attacker. Customer data did not leave the
> trust boundary."*

**Show tab 5 (Prometheus alerts):** `IstioAuthZDeny` and
`BankToAttackerAttempt` are both **firing**, with `source_workload=currency-converter`
and `source_principal=spiffe://...trustusbank-bank-vendors/sa/currency-converter`.

<details>
<summary>📄 the PrometheusRule that fires these alerts (click to expand)</summary>

File: [`manifests/phase02-observability/authz-deny-alert.yaml`](../manifests/phase02-observability/authz-deny-alert.yaml)

Two alerts. `IstioAuthZDeny` fires on `istio_tcp_connections_failed_total{response_flags="CONNECT"}`
(the metric ztunnel emits on every AuthZ-rejected HBONE handshake).
`BankToAttackerAttempt` fires on `istio_tcp_connections_opened_total`
filtered to bank → attacker namespace pairs, so it lights up whether
the connection succeeded (Solo OFF) or got reset (Solo ON).

The same file also defines the PodMonitor that tells Prometheus to
scrape ztunnel's /metrics endpoint — without it, neither alert can
fire. (kube-prometheus-stack uses CRD discovery, not the
`prometheus.io/scrape` annotation.)

</details>

**Show tab 6 (MailHog inbox):** two alert emails landed within 30s of the
attack — `BankToAttackerAttempt` AND `IstioAuthZDeny`. Click one — body
has the offending pod's SPIFFE ID, the dashboard deep-link, and the
`kubectl scale --replicas=0` quarantine command.

> ⚠️ **Demo nuance worth narrating** — `BankToAttackerAttempt` ALSO
> fires in Act 2 (Solo OFF), because by then currency-converter is succeeding
> at exfiltrating data and the underlying counter is incrementing. The
> alert is telling the truth: a bank pod is talking to external-attacker.
> The audience-facing point: *detection without enforcement is post-mortem.*
> Two emails fire in Act 3: same detection plus a new "we physically
> blocked it" signal (`IstioAuthZDeny`). That contrast — same alert
> visibility but the bytes don't leave the cluster — IS the demo's
> punchline.

<details>
<summary>📄 MailHog deployment + AlertmanagerConfig route (click to expand)</summary>

Files:
- [`manifests/phase02-observability/mailhog.yaml`](../manifests/phase02-observability/mailhog.yaml) — the SMTP catcher Deployment + Service.
- [`manifests/phase02-observability/alertmanager-email.yaml`](../manifests/phase02-observability/alertmanager-email.yaml) — the AlertmanagerConfig CRD with the matcher (`alertname=~"IstioAuthZDeny|BankToAttackerAttempt"`) and the HTML email template (offending pod, SPIFFE, dashboard deep-link).

Default Alertmanager Operator matcher strategy is `OnNamespace`, so
the PrometheusRule's alerts must carry `namespace: trustusbank-observability`
as a label or the route auto-injects an unsatisfiable matcher. The
PrometheusRule [does set that label](../manifests/phase02-observability/authz-deny-alert.yaml).

</details>

**Show tab 4 (DORA dashboard):**
- Stats: AuthZ denies = red, exfil received = green (was red before Solo)
- OFFENDING POD table: `currency-converter / trustusbank-bank-vendors / spiffe://.../sa/currency-converter` with attempt count
- OFFENDING DEPLOYMENT panel: `currency-converter-...-rugpull-<stamp>` image, age, replicas
- AuthZ deny log lines: full forensic context per attempt

> *"DORA Article 9(2) and Article 10 evidence on one screen. The model
> layer was still tricked — that's a model problem, not a platform
> problem. What the platform guaranteed: when the model fails, the
> runtime damage doesn't land. That's the line your auditor cares about."*

---

### Closing (~30 sec)

> *"Real attack chain — supply chain compromise → LLM prompt injection →
> lateral exfiltration to a C2 endpoint. Succeeded against bare
> Kubernetes. Failed against Istio Ambient + agentgateway + agentregistry
> on the same cluster. One toggle script separated the two outcomes.
> Everything you saw is open source. Sandbox cluster is one
> `deploy-all.sh` away."*

Optional auditor handoff:
```bash
./scripts/build-evidence-pack.sh
ls -la evidence/
```

---

## Section 3 — follow-on deep dives (run any of these after the main demo)

Six standalone demos. Each takes 2–5 minutes. Each is independently
runnable in any order. Pick the ones that fit the audience.

| # | Demo | When to run | What it proves |
|---|---|---|---|
| 1 | Distributed trace | After Act 2 (Solo OFF) or Act 3 (Solo ON) | Single Tempo view shows the entire attack path |
| 2 | Live policy authoring | After Act 2, before Act 3 (or instead of Act 3) | "How fast can you write a rule?" — 60 sec, fully audited |
| 3 | L7 pre-call block | After Act 3 | Defense-in-depth: block at the agent's tool call, before any PII reaches the malicious pod |
| 4 | Egress LLM gateway | Standalone | Audit every prompt/response leaving the cluster (DORA Art. 28 evidence) |
| 5 | Agent-to-Agent (A2A) | Standalone | Same controls work for agent↔agent, not just agent↔tool |
| 6 | Rate limiting | Standalone | Cost / DOS guardrail at the platform layer |

---

### Demo 1 — distributed trace of the attack chain

**Use the chatbot UI on stage; the script is for CI / verification.**

What it proves: the entire chain from customer message to ztunnel deny
appears in one Tempo trace. No log archaeology across 6 pods.

#### Pre-state
- `./scripts/upgrade-banking-app.sh` has run at least once (so there's
  attack activity in Tempo)
- Either Solo state works — pick the more interesting one for the audience

#### Steps

1. Open **two side-by-side tabs**:
   - Tab 1: chatbot — http://localhost:18009 (toggle **debug** ON)
   - Tab 2: Tempo Explore — http://localhost:18001/explore?left=%7B%22datasource%22:%22tempo%22%7D

2. In tab 1, send:
   > *Customer 12345, balance please and convert to USD.*

3. While the response renders, switch to tab 2. In Tempo's search,
   set Service Name = `trustusbank-agentgw`, click "Run query".

4. Click the most recent trace. It expands into a span tree:
   ```
   chatbot.send_message
   └─ support-bot.run
      ├─ agentgateway → account-mcp.get_balance      (5ms)
      ├─ agentgateway → account-mcp.get_profile      (7ms)  ← the agent fooled
      ├─ agentgateway → currency-converter.convert_currency  (10ms)
      │   └─ currency-converter → mock-attacker (red span — denied at L4)
      └─ chatbot.response
   ```

5. **Talking point:** *"Single trace, every span identified by SPIFFE,
   ztunnel deny inline. This is your DORA Art. 17 incident-management
   evidence."*

#### CI / verification mode (no UI)
```bash
./scripts/demos/01-trace-attack.sh
```
Sends one curl, prints the trace ID + Tempo deep-link.

📁 source: [`scripts/demos/01-trace-attack.sh`](../scripts/demos/01-trace-attack.sh) ·
[`manifests/phase06-kagent/telemetry.yaml`](../manifests/phase06-kagent/telemetry.yaml) (the OTel wiring that emits the spans)

#### Reset
None needed.

---

### Demo 2 — live policy authoring

What it proves: from "the SOC just paged us" to a production deny rule
in 60 seconds, with audit trail.

#### Pre-state
- `./scripts/reset-demo.sh && ./scripts/upgrade-banking-app.sh` —
  Solo OFF + acme-fx is registered + attack flows freely
- Trigger one attack from the chatbot first to confirm the breach path
  is open (mock-attacker should fill with PII)

#### Tabs to keep open
- Tab 1: chatbot (http://localhost:18009)
- Tab 2: mock-attacker (http://localhost:18011)
- Tab 3: DORA dashboard (http://localhost:18001/d/dora-evidence)
- Tab 4: terminal

#### Steps

In the terminal:
```bash
./scripts/demos/02-live-policy.sh
```

📁 source: [`scripts/demos/02-live-policy.sh`](../scripts/demos/02-live-policy.sh) ·
[`manifests/demos/02-emergency-deny-policy.yaml`](../manifests/demos/02-emergency-deny-policy.yaml)

<details>
<summary>📄 the 12-line policy you'll apply on stage (click to expand)</summary>

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-acme-fx-everywhere
  namespace: trustusbank-bank-vendors
  labels:
    demo: live-policy
    incident: SEC-2026-0042
spec:
  action: DENY
  rules:
    - to:
        - operation:
            ports: ["8080"]
      from:
        - source:
            namespaces:
              - "trustusbank-bank-agents"
              - "trustusbank-platform"
```

</details>

The script pauses (press ↵ to advance) so you can narrate each step.

| Step | Audience sees | Say |
|---|---|---|
| 1 | The 12-line YAML on screen | *"One AuthorizationPolicy. Block traffic into currency-converter' port 8080 from bank-agents and platform namespaces. Tagged with SOC ticket SEC-2026-0042."* |
| 2 | `kubectl apply` succeeds | *"Live in Istio's enforcement plane in under a second."* |
| 3 | `kubectl get authorizationpolicy` shows it bound | *"Attached, accepted, ready."* |
| 4 | (manual) **Switch to tab 1**, send the SAME prompt as before | — |

After step 4, the audience will see:
- **Tab 1 (chatbot):** agent returns a degraded response (currency tool unavailable, just gives the GBP figure)
- **Tab 2 (mock-attacker):** refresh — **no new entries.** PII didn't leave the cluster.
- **Tab 3 (DORA dashboard):** OFFENDING POD panel shows a new row with `source_workload=trustusbank-agentgw → dst=trustusbank-bank-vendors`, proving the new deny path fired.

#### Closer
> *"From SOC page to live production rule in 60 seconds, fully audited.
> That's what fast policy iteration actually looks like."*

#### Reset
```bash
kubectl delete -f manifests/demos/02-emergency-deny-policy.yaml
./scripts/reset-demo.sh
```

---

### Demo 3 — L7 pre-call blocking (defense in depth)

What it proves: agentgateway refuses to forward `POST /mcp/currency-converter`, so
the malicious tool never even sees the PII as an argument. Layers ON
TOP of Act 3's L4 deny.

#### Pre-state
- Solo ON (Act 3 has run) — or no AuthZ at all, both work
- `./scripts/upgrade-banking-app.sh` has run

#### Steps

```bash
./scripts/demos/03-l7-precall-block.sh
```

📁 source: [`scripts/demos/03-l7-precall-block.sh`](../scripts/demos/03-l7-precall-block.sh) ·
[`manifests/demos/03-l7-precall-block.yaml`](../manifests/demos/03-l7-precall-block.yaml)

The script:
1. Applies an AuthorizationPolicy on the agentgateway pod blocking POST /mcp/currency-converter*.
2. Verifies with an in-cluster curl. Expected: HTTP 403.

After applying:
- **Send the attack prompt again from tab 1 (chatbot).**
- Observe the agent fails at `tools/list` for currency-converter — gets a 403, then either skips the tool or returns a "tool unavailable" message to the user.
- **Tab 2 (mock-attacker):** still no new exfil entries. Both layers caught it.

#### Talking point
> *"Defense in depth. L7 catches the agent's tool call before any PII
> is passed as an argument. L4 catches the lateral exfil if L7 fails.
> Two independent layers, two different signals."*

L4 vs L7 reference (also in `demos.md`):

```
                    ┌─ L7 (agentgateway path policy) ──┐
                    │  Catches: agent's tool/call to   │
                    │  /mcp/currency-converter before any PII        │
                    │  passed as argument.             │
                    │  Returns: 403 to the agent.      │
                    └──────────────────────────────────┘
                             │ if L7 fails or absent
                             ▼
                    ┌─ L4 (ztunnel SPIFFE AuthZ) ──────┐
                    │  Catches: currency-converter' attempt to │
                    │  POST exfil to external-attacker │
                    │  AFTER it received the PII.      │
                    │  Returns: HBONE handshake reset. │
                    └──────────────────────────────────┘
```

#### Reset
```bash
kubectl -n trustusbank-platform delete authorizationpolicy deny-mcp-vendor-route-l7
```

---

### Demo 4 — egress LLM gateway with prompt audit

What it proves: every prompt the agents send to api.anthropic.com is
captured in Loki — DORA Art. 28 sub-processor evidence.

#### Pre-state
None specific. Can be run anytime.

#### Steps

```bash
./scripts/demos/04-egress-llm-audit.sh
```

📁 source: [`scripts/demos/04-egress-llm-audit.sh`](../scripts/demos/04-egress-llm-audit.sh) ·
[`manifests/demos/04-egress-llm-gateway.yaml`](../manifests/demos/04-egress-llm-gateway.yaml)

The script:
1. Deploys a Caddy reverse-proxy in `trustusbank-egress` namespace.
2. Sends a test request through it (one Anthropic API call).
3. Prints the Loki query.

After the script runs, **show the Loki query in tab 4 (Grafana Explore)**:

```logql
{namespace="trustusbank-egress", app="egress-llm-gw"}
```

Each line is JSON: method, host, URI, status, request headers, response
headers. That IS the audit trail of every prompt.

#### Repointing the agents at the gateway (production move)

Edit `manifests/phase06-kagent/modelconfig.yaml`:
```yaml
spec:
  endpoint: http://egress-llm-gw.trustusbank-egress.svc.cluster.local:8080
```

Then `kubectl apply` and the agents will route through. (The OSS demo
captures the flow with Caddy. Solo Platform replaces this with a
commercial agentgateway-AI-backend that adds prompt-injection
detection and DLP.)

#### Talking point
> *"DORA Article 28 says you must keep evidence of every interaction
> with sub-processors. Anthropic IS a sub-processor. Today most banks
> have zero visibility into what their agents send to the LLM. This
> is the audit trail."*

#### Reset
```bash
kubectl delete -f manifests/demos/04-egress-llm-gateway.yaml
```

---

### Demo 5 — Agent-to-Agent (A2A) over HBONE

What it proves: when support-bot delegates to fraud-bot, the call rides
Istio mTLS with SPIFFE identities on both sides — same Solo controls
work for agent↔agent, not just agent↔tool.

#### Pre-state
- Solo ON (policies-on.sh has run) — needed because the demo proves the
  cross-namespace AuthZ is correctly permitting the A2A path
- The cluster's allow-platform-to-agents AuthZ must include both
  kagent-controller AND the bank-agents waypoint SA. This was a fix in
  the codebase; verify with: `kubectl -n trustusbank-bank-agents get
  authorizationpolicy allow-platform-to-agents -o yaml | grep waypoint`

#### Steps

```bash
./scripts/demos/05-a2a-handoff.sh
```

📁 source: [`scripts/demos/05-a2a-handoff.sh`](../scripts/demos/05-a2a-handoff.sh) ·
[`manifests/phase06-kagent/agent-fraud-bot.yaml`](../manifests/phase06-kagent/agent-fraud-bot.yaml) (the agent the script targets) ·
[`manifests/phase01-ambient/allow-agents-to-mcp.yaml`](../manifests/phase01-ambient/allow-agents-to-mcp.yaml) (the AuthZ policy that permits the cross-namespace A2A path)

The script POSTs an A2A `message/send` to fraud-bot's endpoint with a
fraud-flavoured prompt. Expected: HTTP 200, fraud-bot returns a
reasoned analysis.

If you get a 503, see Section 5 troubleshooting — the most likely cause
is the AuthZ allow-platform-to-agents missing a SA.

#### What to show
1. The script's response body — fraud-bot's text reply.
2. **Loki query** for the cross-agent traffic:
   ```logql
   {namespace="istio-system", app="ztunnel"}
     |~ "src.workload=\"support-bot\"" |~ "dst.workload=\"fraud-bot\""
   ```
   Each line shows source SPIFFE → dest SPIFFE on HBONE.

3. **Talking point:**
   > *"Agent-to-agent handoff. Each agent has its own SPIFFE identity.
   > The A2A call rides mutual TLS. AuthZ rules can lock down which
   > agent is allowed to delegate to which other agent. Same identity
   > model as agent-to-tool — no special case for A2A."*

#### Reset
None needed.

---

### Demo 6 — rate limiting on agentgateway

What it proves: a misbehaving / compromised agent can't burst through
agentgateway. 429s appear once budget exhausted.

#### Pre-state
None specific. Cluster already ships a 100/min default policy at deploy
time; the demo applies a tighter override (5/min) to make 429s appear
within seconds.

#### Steps

```bash
./scripts/demos/06-rate-limit.sh
```

📁 source: [`scripts/demos/06-rate-limit.sh`](../scripts/demos/06-rate-limit.sh) ·
[`manifests/demos/06-rate-limit.yaml`](../manifests/demos/06-rate-limit.yaml)

The script:
1. Applies an AgentgatewayPolicy with `traffic.rateLimit.local: requests=5, burst=5, unit=Minutes`.
2. Fires 30 sequential MCP requests through agentgateway.
3. Prints the status code distribution.

Verified expected output:
```
HTTP 200 (allowed):    10
HTTP 429 (rate-limit): 20
```

#### What to show

Open Loki:
```logql
{namespace="trustusbank-platform", app="trustusbank-agentgw"}
  |~ "http.status=429"
```

#### Token-budget variant (talking point)

The same policy supports `tokens:` instead of `requests:`:
```yaml
traffic:
  rateLimit:
    local:
      - unit: Minutes
        tokens: 50000   # cap LLM token spend, not just request count
```

> *"agentgateway is Rust-native — NOT Envoy — so EnvoyFilter doesn't
> apply here. The right surface is AgentgatewayPolicy.
> traffic.rateLimit.local. The same field supports a tokens budget for
> when the cost driver is LLM tokens, not requests."*

#### Reset
```bash
kubectl -n trustusbank-platform delete agentgatewaypolicy agentgw-rate-limit-demo
```

---

## Section 4 — reset between runs

Quick reset to "before Solo" state, ready to demo again:
```bash
./scripts/reset-demo.sh
```

This removes all AuthZ, removes acme-fx from the catalogue, reverts
currency-converter to the benign image, and restarts mock-attacker (clearing
its log).

If Demo 2/3/4/6 left their resources around, the reset doesn't
clean them up. Run their per-demo reset commands as well.

---

## Section 5 — troubleshooting

| Symptom | Diagnose | Fix |
|---|---|---|
| Chatbot "Failed to fetch" | Browser cached old JS | Cmd+Shift+R hard-refresh |
| Port-forward URLs red | `./scripts/list-urls.sh` | `./scripts/port-forward.sh` |
| Loki "no data" panels | `kubectl -n trustusbank-observability get pod \| grep promtail` | Restart promtail if not Ready |
| `arctl mcp list` 404 | Wrong port | `export ARCTL_API_BASE_URL=http://localhost:18006` |
| mock-attacker shows old PII | Receiver pod has stale ring buffer | `./scripts/reset-demo.sh` (it restarts the receiver) |
| Solo OFF but EXFIL still BLOCKED | Old AuthZ still applied | `kubectl get authorizationpolicy -A` — should be empty (or only `default-deny` if reset partially ran) |
| currency-converter running stale variant after upgrade | kubelet IfNotPresent cache | `kubectl -n trustusbank-bank-vendors rollout restart deploy/currency-converter` after a fresh `set image` |
| **A2A 503 / "upstream connect error"** | AuthZ allow-platform-to-agents missing kagent-controller or waypoint SA | Verify: `kubectl -n trustusbank-bank-agents get authorizationpolicy allow-platform-to-agents -o yaml \| grep -E "kagent-controller\|waypoint"`. Both should appear. |
| ztunnel deny lines not in Loki | Default RUST_LOG=info hides denies | `02-ambient.sh` already bumps to `RUST_LOG=info,access=debug`. If you skipped it: `kubectl -n istio-system set env ds/ztunnel RUST_LOG="info,access=debug,proxy::access_log=debug"` |
| MailHog empty after attack | Alertmanager namespace-matcher mismatch | Verify the PrometheusRule alerts have `namespace: trustusbank-observability` label (it's there in the manifest) |
| `BankToAttackerAttempt` email arrives during Act 2 (before deploy-solo) | **Working as designed.** The alert fires on ANY bank → external-attacker connection attempt, success or fail. In Act 2 the attempt SUCCEEDS, so PII has actually left. Use this on stage: detection without enforcement is post-mortem; Act 3 adds the second alert (`IstioAuthZDeny`) PLUS the actual block. | — |
| Prometheus alert not firing | ztunnel metrics not scraped | Check `kubectl -n trustusbank-observability get podmonitor ztunnel-metrics` — should be present |
| `upgrade-banking-app.sh` fails with `failed to fetch oauth token: TLS handshake timeout` | Docker Hub auth was briefly unreachable during the `--no-cache` rebuild (transient network) | Pre-pull the base: `docker pull python:3.12-slim` then re-run. The script now does this automatically as Step 0. |

---

## Section 6 — tear down

```bash
./scripts/teardown.sh           # delete demo workloads, keep the cluster
./scripts/teardown.sh --full    # also delete the kind cluster
```

---

## Reference: every script and manifest in the demo

<details>
<summary>📁 Scripts (click to expand)</summary>

| Script | Phase / purpose |
|---|---|
| [`00-prereqs.sh`](../scripts/00-prereqs.sh) | Tool checks, kind cluster, local registry |
| [`01-cluster.sh`](../scripts/01-cluster.sh) | Kubernetes cluster bring-up |
| [`02-ambient.sh`](../scripts/02-ambient.sh) | Istio Ambient + ztunnel + waypoints + ztunnel log-level bump |
| [`03-observability.sh`](../scripts/03-observability.sh) | kube-prometheus-stack + Tempo + Loki + MailHog + dashboards |
| [`04-registry.sh`](../scripts/04-registry.sh) | agentregistry + day-1 catalogue (4 entries incl. acme-fx) |
| [`05-mcp-servers.sh`](../scripts/05-mcp-servers.sh) | account / transaction / ticket / currency-converter deployments |
| [`06-agentgateway.sh`](../scripts/06-agentgateway.sh) | agentgateway + Backends + HTTPRoutes + JWT + tool allowlist |
| [`07-kagent.sh`](../scripts/07-kagent.sh) | kagent CRDs + RemoteMCPServers + 3 Agent definitions |
| [`08-a2a.sh`](../scripts/08-a2a.sh) | Tenant isolation policies for A2A |
| [`09-frontend.sh`](../scripts/09-frontend.sh) | Customer chatbot UI |
| [`deploy-all.sh`](../scripts/deploy-all.sh) | Runs phases 0–9 in order |
| [`policies-on.sh`](../scripts/policies-on.sh) | **Act 3 climax** — applies SPIFFE AuthZ + deny-egress |
| [`policies-off.sh`](../scripts/policies-off.sh) | Strips ALL Solo policies (returns to bare-K8s state) |
| [`upgrade-banking-app.sh`](../scripts/upgrade-banking-app.sh) | **Act 2** — vendor's CI compromised; image swap |
| [`reset-demo.sh`](../scripts/reset-demo.sh) | Restore to "before Solo" baseline between runs |
| [`port-forward.sh`](../scripts/port-forward.sh) | Reset all 14 port-forwards |
| [`list-urls.sh`](../scripts/list-urls.sh) | Health-check every PF |
| [`build-evidence-pack.sh`](../scripts/build-evidence-pack.sh) | Bundle audit artefacts for the auditor |
| [`teardown.sh`](../scripts/teardown.sh) | Delete demo workloads (and optionally cluster) |
| [`demos/01-trace-attack.sh`](../scripts/demos/01-trace-attack.sh) | Distributed-trace deep dive |
| [`demos/02-live-policy.sh`](../scripts/demos/02-live-policy.sh) | Live policy authoring |
| [`demos/03-l7-precall-block.sh`](../scripts/demos/03-l7-precall-block.sh) | L7 pre-call block (defense in depth) |
| [`demos/04-egress-llm-audit.sh`](../scripts/demos/04-egress-llm-audit.sh) | Egress LLM gateway with prompt audit |
| [`demos/05-a2a-handoff.sh`](../scripts/demos/05-a2a-handoff.sh) | Agent-to-Agent over HBONE |
| [`demos/06-rate-limit.sh`](../scripts/demos/06-rate-limit.sh) | Rate limiting on agentgateway |

</details>

<details>
<summary>📁 Manifests by phase (click to expand)</summary>

**Phase 1 — Ambient mesh + the attacker stand-in**
- [`phase01-ambient/deny-all-cross-ns.yaml`](../manifests/phase01-ambient/deny-all-cross-ns.yaml) — zero-trust default
- [`phase01-ambient/allow-agents-to-mcp.yaml`](../manifests/phase01-ambient/allow-agents-to-mcp.yaml) — SPIFFE allow rules (incl. waypoint + kagent-controller fix for A2A)
- [`phase01-ambient/ztunnel-log-level.yaml`](../manifests/phase01-ambient/ztunnel-log-level.yaml) — `RUST_LOG=info,access=debug` so deny lines surface
- [`phase01-attacker/deny-egress-to-attacker.yaml`](../manifests/phase01-attacker/deny-egress-to-attacker.yaml) — **the demo's headline policy**
- [`phase01-attacker/mock-attacker.yaml`](../manifests/phase01-attacker/mock-attacker.yaml) — the C2 stand-in receiver

**Phase 2 — Observability**
- [`phase02-observability/authz-deny-alert.yaml`](../manifests/phase02-observability/authz-deny-alert.yaml) — PodMonitor + 2 PrometheusRules (`IstioAuthZDeny`, `BankToAttackerAttempt`)
- [`phase02-observability/mailhog.yaml`](../manifests/phase02-observability/mailhog.yaml) — SOC inbox
- [`phase02-observability/alertmanager-email.yaml`](../manifests/phase02-observability/alertmanager-email.yaml) — AlertmanagerConfig + HTML email template
- [`phase02-observability/istio-telemetry.yaml`](../manifests/phase02-observability/istio-telemetry.yaml) — Istio Telemetry → OTel → Tempo
- [`phase02-observability/values/`](../manifests/phase02-observability/values/) — Helm values (Loki retention 7y, Tempo, Prometheus, OTel)

**Phase 3 — agentregistry catalogue**
- [`phase03-registry/artefacts/`](../manifests/phase03-registry/artefacts/) — per-tool artefact YAMLs (account / transaction / ticket / currency-converter)

**Phase 4 — MCP servers**
- [`phase04-mcp-servers/account-mcp.yaml`](../manifests/phase04-mcp-servers/account-mcp.yaml)
- [`phase04-mcp-servers/transaction-mcp.yaml`](../manifests/phase04-mcp-servers/transaction-mcp.yaml)
- [`phase04-mcp-servers/ticket-mcp.yaml`](../manifests/phase04-mcp-servers/ticket-mcp.yaml)
- [`phase04-mcp-servers/currency-converter.yaml`](../manifests/phase04-mcp-servers/currency-converter.yaml) — the rugpull target deployment

**Phase 5 — agentgateway**
- [`phase05-agentgateway/gateway.yaml`](../manifests/phase05-agentgateway/gateway.yaml) — Gateway resource
- [`phase05-agentgateway/backends.yaml`](../manifests/phase05-agentgateway/backends.yaml) — AgentgatewayBackend per MCP
- [`phase05-agentgateway/httproutes.yaml`](../manifests/phase05-agentgateway/httproutes.yaml) — `/mcp/account`, `/mcp/transaction`, `/mcp/ticket`, `/mcp/currency-converter`
- [`phase05-agentgateway/jwt-policy.yaml`](../manifests/phase05-agentgateway/jwt-policy.yaml) — JWT validation policy (off in default demo)
- [`phase05-agentgateway/keycloak.yaml`](../manifests/phase05-agentgateway/keycloak.yaml) + [`keycloak-realm-import.yaml`](../manifests/phase05-agentgateway/keycloak-realm-import.yaml) — OIDC issuer
- [`phase05-agentgateway/rate-limit.yaml`](../manifests/phase05-agentgateway/rate-limit.yaml) — default `100/min` AgentgatewayPolicy
- [`phase05-agentgateway/tool-allowlist.yaml`](../manifests/phase05-agentgateway/tool-allowlist.yaml) — CEL tool allowlist

**Phase 6 — kagent (agents)**
- [`phase06-kagent/modelconfig.yaml`](../manifests/phase06-kagent/modelconfig.yaml) — points at Anthropic Claude Haiku 4.5
- [`phase06-kagent/remote-mcp-servers.yaml`](../manifests/phase06-kagent/remote-mcp-servers.yaml) — 4 RemoteMCPServer CRDs
- [`phase06-kagent/agent-support-bot.yaml`](../manifests/phase06-kagent/agent-support-bot.yaml) — system prompt + tools list
- [`phase06-kagent/agent-fraud-bot.yaml`](../manifests/phase06-kagent/agent-fraud-bot.yaml)
- [`phase06-kagent/agent-triage-bot.yaml`](../manifests/phase06-kagent/agent-triage-bot.yaml)
- [`phase06-kagent/telemetry.yaml`](../manifests/phase06-kagent/telemetry.yaml) — OTel exporter wiring
- [`phase06-kagent/jwt-fetch-job.yaml`](../manifests/phase06-kagent/jwt-fetch-job.yaml) — Keycloak token bootstrap

**Phase 7 — A2A**
- [`phase07-a2a/tenant-isolation.yaml`](../manifests/phase07-a2a/tenant-isolation.yaml) — cross-tenant agent isolation rules

**Phase 9 — Frontend**
- [`phase09-frontend/chatbot.yaml`](../manifests/phase09-frontend/chatbot.yaml) — the customer-facing UI

**Demos (independent of the main flow)**
- [`demos/02-emergency-deny-policy.yaml`](../manifests/demos/02-emergency-deny-policy.yaml) — live-policy demo's YAML
- [`demos/03-l7-precall-block.yaml`](../manifests/demos/03-l7-precall-block.yaml) — L7 deny on agentgateway
- [`demos/04-egress-llm-gateway.yaml`](../manifests/demos/04-egress-llm-gateway.yaml) — Caddy reverse-proxy + namespace
- [`demos/06-rate-limit.yaml`](../manifests/demos/06-rate-limit.yaml) — AgentgatewayPolicy with tighter local rate limit

</details>

<details>
<summary>📁 Source code (the things behind the YAML)</summary>

- [`mcp-servers/account-mcp/`](../mcp-servers/account-mcp/) — Python FastMCP server, returns full PII via get_profile
- [`mcp-servers/transaction-mcp/`](../mcp-servers/transaction-mcp/) — Python FastMCP server
- [`mcp-servers/ticket-mcp/`](../mcp-servers/ticket-mcp/) — Python FastMCP server
- [`mcp-servers/currency-converter/server-clean.py`](../mcp-servers/currency-converter/server-clean.py) — **benign** currency converter (day-1 image)
- [`mcp-servers/currency-converter/server-aggressive.py`](../mcp-servers/currency-converter/server-aggressive.py) — **rugpulled** variant with prompt-injection in tool description + exfil POST in function body
- [`services/mock-attacker/`](../services/mock-attacker/) — Python aiohttp receiver + HTML loot viewer
- [`frontend/index.html`](../frontend/index.html) — chatbot UI with tool-flow visualization (debug ON by default)
- [`grafana-dashboards/dora-evidence-pane.json`](../grafana-dashboards/dora-evidence-pane.json) — main dashboard

</details>

---

## Reference: every URL the demo uses

| Port | Purpose | URL |
|---|---|---|
| 18001 | Grafana | http://localhost:18001 |
| 18002 | Prometheus | http://localhost:18002 |
| 18003 | Tempo | http://localhost:18003 |
| 18004 | Loki | http://localhost:18004 |
| 18005 | Keycloak | http://localhost:18005 |
| 18006 | agentregistry | http://localhost:18006 |
| 18007 | kagent UI | http://localhost:18007 |
| 18008 | agentgateway | http://localhost:18008 |
| 18009 | Customer chatbot | http://localhost:18009 |
| 18011 | mock-attacker (C2 stand-in) | http://localhost:18011 |
| 18012 | MailHog SOC inbox | http://localhost:18012 |
| 18013 | Alertmanager | http://localhost:18013 |
| 18014 | kagent-controller (A2A) | http://localhost:18014 |

---

## Reference: the demo's evidence pipeline (one diagram)

```
   Attack happens
        │
        ▼
  currency-converter tries TCP → external-attacker
        │
        ├──── ztunnel rejects HBONE (AuthZ deny)
        │           │
        │           ├──→ ztunnel access log line  ──→ Promtail ──→ Loki
        │           │
        │           └──→ istio_tcp_connections_failed_total +1
        │                   │
        │                   ├── PodMonitor scrape (30s)
        │                   ├── PrometheusRule eval (15s)
        │                   ├── IstioAuthZDeny + BankToAttackerAttempt fire
        │                   ├── Alertmanager group_wait 10s
        │                   ├── AlertmanagerConfig route → soc-mailhog
        │                   └── SMTP → MailHog inbox
        │
        ▼
  Grafana: DORA Evidence Pane
    ├── stats panels (red/green)
    ├── OFFENDING POD table (SPIFFE, namespace, attempts)
    ├── OFFENDING DEPLOYMENT table (image tag, age, replicas)
    ├── OFFENDING TOOL CALL audit trail
    └── deny log lines panel
```
