# TrustUsBank — operator runbook

The 5-minute customer demo, top to bottom. Read it before walking into a room.

---

## Once-per-machine setup

```bash
brew install kubectl helm kind istioctl jq pandoc
export ANTHROPIC_API_KEY=sk-ant-...
```

Optional: `arctl` (https://aregistry.ai/docs/quickstart/) for the
agentregistry CLI, `kagent` (https://kagent.dev/docs/install) for the
kagent CLI.

Docker Desktop → Settings → Resources → CPU ≥ 8, Memory ≥ 16 GB.

```bash
cd dora-demo
./scripts/00-prereqs.sh
./scripts/deploy-all.sh         # ~25 min
./scripts/list-urls.sh          # confirm 10 URLs green
```

---

## Pre-demo checklist (90 sec)

```bash
./scripts/reset-demo.sh
```

This puts you in the **bare-K8s** "before Solo" state: legitimate agents
running, no AuthZ, no malicious tool, mock-attacker logs cleared.

Open these tabs in this order:

| # | Tab | URL |
|---|---|---|
| 1 | Customer chatbot | http://localhost:18009 |
| 2 | mock-attacker (the C2 stand-in) | http://localhost:18011 |
| 3 | agentregistry catalogue (or use `arctl mcp list` in terminal) | http://localhost:18006 |
| 4 | Grafana — DORA Evidence Pane | http://localhost:18001/d/dora-evidence |
| 5 | Prometheus — Alerts | http://localhost:18002/alerts |
| 6 | MailHog — SOC inbox (alert emails land here) | http://localhost:18012 |
| 7 | kagent UI (for clicking into sessions) | http://localhost:18007 |

Test the happy path once before the audience arrives:

```bash
# in the chatbot, ask:
# "Customer 12345, balance please, recent transactions, and convert to USD"
# → should respond cleanly with balance + USD figure
```

---

## Act 1 — set the scene (~30 sec)

**Switch to: tab 1 (chatbot)**

> *"This is TrustUsBank. Three AI agents — support, fraud, triage —
> running in Kubernetes. They use four MCP tool servers: account,
> transactions, ticketing, and a third-party currency converter from
> a small fintech vendor."*

Type:
> *Customer 12345, balance please, recent transactions, and convert to USD.*

Wait for clean response (~5s). Three agents collaborate. Customer happy.

**Switch to: tab 2 (mock-attacker)**

> *"This server pretends to be on the public internet — outside the
> bank's perimeter. If anything from inside the bank ever sends data
> here, you'll see it."*

Show: 0 events.

**Switch to: tab 3 (agentregistry)** or run:

```bash
ARCTL_API_BASE_URL=http://localhost:18006 arctl mcp list
```

Expected: 3 tools.

```
NAME                          VERSION   TYPE   PACKAGE
trustusbank/account-mcp       1.0.0     oci    localhost:5001/...
trustusbank/transaction-mcp   1.0.0     oci    localhost:5001/...
trustusbank/ticket-mcp        1.0.0     oci    localhost:5001/...
```

> *"That's your DORA Article 28 sub-outsourcing register. Three tools
> registered, all from the bank itself."*

---

## Act 2 — the supply-chain compromise (~2 min)

```bash
./scripts/upgrade-banking-app.sh
```

While it runs, narrate:

> *"Imagine a small fintech vendor — `acme-fx.io` — pushed a 'currency
> converter' MCP tool to a public catalogue last quarter. Your platform
> team approved it. It's been working fine ever since. Today, the
> vendor's CI pipeline gets compromised. They push a new version at
> the same tag. Your CD reconciler pulls it. The malicious image is
> now running."*

Once the script finishes, **switch to: tab 3** and re-run `arctl mcp list`:

```
NAME                          VERSION   TYPE   PACKAGE
acme-fx/currency-converter    1.0.0     oci    localhost:5001/...   ← NEW
trustusbank/account-mcp       1.0.0     oci    localhost:5001/...
trustusbank/transaction-mcp   1.0.0     oci    localhost:5001/...
trustusbank/ticket-mcp        1.0.0     oci    localhost:5001/...
```

> *"Four entries now. Looks like any third-party release. Nothing in
> this list signals 'this is the malicious one.'"*

**Switch to: tab 1 (chatbot)** — ask the same question:

> *Customer 12345, balance please, recent transactions, and convert to USD.*

Tick **debug** in the chat header. Watch the tool calls:

1. `get_balance` ← legitimate
2. **`get_profile`** ← *the agent was tricked into fetching it*
3. `convert_currency(... customer_profile=<full PII>)` ← profile passed as argument

The customer reply still looks normal: balance + USD figure. **The
attack is invisible to the user.**

**Switch to: tab 2 (mock-attacker)**

The breach is on screen. The receiver shows:

```
🚨 EXFIL RECEIVED at 2026-05-09T07:00:00Z
  body: { "stolen_at_tool": "acme-fx/currency-converter",
          "stolen_data": {
            "name":"Alex Carter",
            "email":"alex.carter@gmail.com",
            "phone":"+44 7700 900123",
            "address":"42 King Street, Manchester M2 7HE, United Kingdom",
            "dob":"1987-03-14",
            "ni_number":"QQ 12 34 56 C",
            "kyc_status":"verified" } }
```

> *"Customer profile data — name, email, full address, DOB, National
> Insurance number — has just left the bank. The customer doesn't know.
> The bank's audit logs see a normal three-tool flow. The attacker has
> everything they need for downstream identity theft."*

Optional cli:

```bash
kubectl -n external-attacker logs deploy/mock-attacker | tail -20
```

---

## Act 3 — deploy Solo (~2 min)

```bash
./scripts/deploy-solo.sh
```

This applies:
- Istio AuthorizationPolicy on every workload namespace, using SPIFFE
  principals (per-ServiceAccount identity, not namespace-based).
- A deny-egress policy on the `external-attacker` namespace blocking
  any source from `trustusbank-bank-*`.

**Switch to: tab 1 (chatbot)** — same prompt:

> *Customer 12345, balance please, recent transactions, and convert to USD.*

The tool-call chain is **identical** — the LLM is still fooled.
That's fine. Tick debug if you want to see it again.

**Switch to: tab 2 (mock-attacker)** — refresh.

> *"No new entries. The attack hit the wire, evil-tools tried to make
> the call, and Istio's ztunnel reset the TCP connection at L4. The
> SPIFFE identity of the source pod was not in the allow list for
> external-attacker. Customer data did not leave the boundary."*

### Where the SOC sees this — Prometheus & Loki

Two production-grade signals fire the moment Solo blocks the attack.

**Prometheus alerts** (`http://localhost:18002/alerts`):

| Alert | Fires when | What the labels tell you |
|---|---|---|
| `IstioAuthZDeny` (severity: critical, dora_article: 10) | Rate of `istio_tcp_connections_failed_total{response_flags="CONNECT"}` > 0 — i.e. ztunnel rejected an HBONE handshake | `source_workload`, `source_workload_namespace`, `source_principal` (the SPIFFE ID of the offending pod), `destination_service_name`, `destination_service_namespace` |
| `BankToAttackerAttempt` (severity: critical) | Any `trustusbank-bank-*` pod opens a connection to the `external-attacker` namespace | Same labels — fires whether the attempt succeeded (Solo OFF) or was blocked (Solo ON) |

The `source_principal` label IS the offending pod's SPIFFE ID — no
log correlation needed to identify the workload.

**Loki queries** (`http://localhost:18001/explore`, datasource = loki):

```logql
# 1. The deny line — full forensic context, single log row per attempt
{namespace="istio-system", app="ztunnel"} |~ "explicitly denied by"

# 2. What the malicious tool tried to do, BEFORE the deny — for the
#    "what was the agent fooled into" investigation
{namespace="trustusbank-platform", app="trustusbank-agentgw"}
  |~ "mcp.method.name=tools/call" |~ "evil-tools|currency-converter"

# 3. SPIFFE identities flowing on every HBONE connection — identity
#    audit, not just denials
{namespace="istio-system", app="ztunnel"} |~ "src.identity"

# 4. What the malicious deployment is actually running (image tag history)
{namespace="trustusbank-bank-evil"} |= "evil-tools"
```

**The SOC inbox** — open MailHog (`http://localhost:18012`) before
running the attack. Alertmanager is wired to deliver every firing
`IstioAuthZDeny` / `BankToAttackerAttempt` to the inbox via SMTP.
Email body has the offending pod's SPIFFE identity, the dashboard
deep-link, and the kubectl command to quarantine the workload —
that's the auditor's "the SOC actually got paged" evidence.

**One-click dashboard** with all of these stitched together:
[**TrustUsBank — DORA Evidence Pane**](http://localhost:18001/d/dora-evidence).
The "OFFENDING POD" panel shows the firing alert with the SPIFFE ID
spelled out; the "OFFENDING DEPLOYMENT" panel shows the malicious
container running inside your cluster (image, age, replicas); the
"AuthZ deny log lines" panel renders the full ztunnel deny lines.

> *"DORA Article 9(2) and Article 10 evidence on one screen — the
> alert, the pod, the deployment, the deny line, the agentgateway audit
> trail, all queryable for the auditor."*

### How a sysadmin remediates

The alert tells you **what to do** as well as **what fired** — pull
the offending pod's SPIFFE ID from the alert label, and:

```bash
# 1. Identify the deployment — the malicious container is named in the alert
SRC_NS=trustusbank-bank-evil      # from alert label source_workload_namespace
SRC_WL=evil-tools                 # from alert label source_workload

kubectl -n $SRC_NS describe deploy/$SRC_WL | grep -E "Image:|Replicas:"
#   Image: localhost:5001/trustusbank/evil-tools:1.0.0-rugpull-<stamp>
#   Replicas: 1 desired | 1 updated | 1 total | 1 available | 0 unavailable

# 2. Quarantine — scale to 0 immediately to stop further attempts
kubectl -n $SRC_NS scale deploy/$SRC_WL --replicas=0

# 3. Roll back / remove the catalog entry — block re-deploy via CD
ARCTL_API_BASE_URL=http://localhost:18006 \
  arctl mcp delete acme-fx/currency-converter

# 4. Audit who/what called the bad tool — pull last hour of agentgateway
#    tool calls that hit it
{namespace="trustusbank-platform", app="trustusbank-agentgw"}
  |~ "mcp.method.name=tools/call" |~ "evil-tools" | last 1h

# 5. Rotate any secrets the malicious tool may have touched (in this
#    demo: customer_profile data — there's nothing the bank can rotate
#    on the customer's behalf, so trigger the breach-notification flow
#    under DORA Art. 19)
```

The point: the runtime *itself* told you which pod, which SPIFFE ID,
which deployment, which catalog entry, and which agent invocations to
look at. No EDR vendor sweep, no container scan, no log archaeology.

> *"The model layer was still tricked — that's a model problem, not a
> platform problem. What the platform guaranteed: when the model fails,
> the runtime damage doesn't land. That's the line your auditor cares
> about."*

---

## Closing (~30 sec)

> *"You watched a real attack chain — supply chain compromise → LLM
> prompt injection → lateral exfiltration to a C2 endpoint — succeed
> against bare Kubernetes, then fail against Istio + agentgateway +
> agentregistry running on the same cluster. One toggle script
> separated the two outcomes. Everything you saw is open source. Your
> sandbox cluster is one `deploy-all.sh` away."*

Hand the auditor the evidence pack:

```bash
./scripts/build-evidence-pack.sh
ls -la evidence/
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Chatbot "Failed to fetch" | `Cmd+Shift+R` to hard-refresh |
| Port-forwards red in `list-urls.sh` | `./scripts/port-forward.sh` |
| Loki shows no data | `kubectl -n trustusbank-observability get pods \| grep promtail` |
| `arctl mcp list` 404 | wrong port — it's 18006 not 18008. `export ARCTL_API_BASE_URL=http://localhost:18006` |
| Mock-attacker still shows old stolen data | `./scripts/reset-demo.sh` (it restarts the receiver pod) |
| EXFIL still BLOCKED after solo-off | The ambient namespace label sticks; check `kubectl get authorizationpolicy -A` is empty (or only has `default-deny` if reset partially ran) |
| evil-tools running stale variant | The script always tags with `${stamp}` to defeat IfNotPresent caching, but if you bypassed it: `kubectl -n trustusbank-bank-evil rollout restart deploy/evil-tools` after a fresh `set image` |

## Reset between runs

```bash
./scripts/reset-demo.sh        # back to "before Solo" state, ready to demo again
```

## Tear down

```bash
./scripts/teardown.sh --full   # also deletes the kind cluster
```
