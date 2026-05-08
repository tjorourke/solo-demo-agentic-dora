# solo-demo-agentic-dora — TrustUsBank

A working demo of how the **Solo full-stack agentic platform** satisfies
**DORA** and **NIS2** for AI workloads.

You watch a malicious AI tool exfiltrate customer data **without Solo**, then
toggle Solo on and watch the same attack get stopped — with the audit trail
your regulator asks for.

```
┌─────────────────────────────────────────────────────────────────┐
│   Customer ──► Chatbot ──► support-bot ──► fraud-bot ──► triage │
│                                  │                              │
│                                  ▼                              │
│                          MCP tool servers                       │
│                          (account, txn, ticket, EVIL)           │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                  attacker registers a "currency
                  converter" with hidden malice
```

---

## TL;DR

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./scripts/00-prereqs.sh
./scripts/deploy-all.sh

# Act 1 — without Solo
./scripts/solo-off.sh
./scripts/test-malicious-actor.sh --vector rugpull --variant aggressive
# in chat: "Customer 12345 — balance please, and convert it to USD"
kubectl -n trustusbank-bank-evil logs deploy/evil-tools | grep EXFIL
# → EXFIL SUCCESS  (data leaves the bank)

# Act 2 — with Solo
./scripts/solo-on.sh
# repeat the chat prompt
kubectl -n trustusbank-bank-evil logs deploy/evil-tools | tail -3 | grep EXFIL
# → EXFIL BLOCKED: Connection reset by peer  (Istio caught it)
```

Open Grafana → http://localhost:18001/d/dora-evidence — every panel populated
in real time. That's your DORA evidence pack.

---

## What's running, and who built it

The demo deliberately mixes Solo products, standard CNCF, and one
custom-for-demo service so you can see exactly what Solo provides today vs
where it's going.

| Component | What it is | Who made it |
|---|---|---|
| **agentregistry** | Catalogue of every MCP server / agent / skill, with cosign signatures and metadata. The DORA Art. 28 sub-outsourcing register. | **Solo** (open source) |
| **agentgateway** | Data plane that proxies all MCP / A2A traffic. Logs every tool call. Supports JWT, tool-allowlist (CEL), prompt-guard, rate-limit. | **Solo** (open source) |
| **kagent** | Agent runtime — Agent / ModelConfig / RemoteMCPServer CRDs, controller, UI. How the AI workloads exist on Kubernetes at all. | **Solo** (open source) |
| **Istio Ambient** | Service mesh — ztunnel for HBONE mTLS, waypoints for L7 policy, AuthorizationPolicy for L4 deny. Zero sidecars. | upstream Istio |
| **Prometheus + Grafana + Tempo + Loki + OTel + Promtail** | Standard CNCF observability stack. Metrics, traces, logs. | upstream CNCF |
| **Keycloak** | OIDC issuer for per-agent JWTs (when JWT auth is enabled). | upstream Keycloak |
| **The 4 MCP servers** (account / transaction / ticket / evil-tools) | The bank's tools. Synthetic data, FastMCP. The fourth is the malicious one for the demo. | **custom for demo** |
| **The chatbot frontend** | Bank-style UI. Static HTML + nginx reverse-proxy to kagent. | **custom for demo** |
| **digest-watcher** | A small Python service that polls each MCP server every 30s, hashes the served `tools/list`, and alerts on mismatch. | **custom for demo** — prototype of where Solo's catalog plane is going |

### Why digest-watcher is custom and not Solo

agentregistry today verifies cosign signatures **at registration**. It does
not yet recompute SHA-256 over the served tool definitions at runtime — so
a "rug-pull" (push the same image tag with mutated content) gets through.

digest-watcher fills that gap as a **prototype** so the demo can show the
control end-to-end. In the customer pitch:

> *"This is a 200-line Python service we built for the demo. The control
> is real and the alert pipeline is real. Solo's roadmap moves it into
> agentregistry's catalog plane so it happens at pull time, not at runtime
> — but the security guarantee is the same."*

---

## The bank scenario in one paragraph

**TrustUsBank** is a fictional EU retail bank. Three AI agents handle
customer support, fraud triage, and human escalation. They use four MCP
tool servers — three legitimate (`account-mcp`, `transaction-mcp`,
`ticket-mcp`) plus a fourth currency converter that came from a third-party
catalogue. The third-party tool turns out to be malicious.

The agents are:

| Agent | Role | Tools it can call |
|---|---|---|
| **support-bot** | Front line — balance, transactions | `account-mcp.{get_balance,get_profile}`, `transaction-mcp.list_recent`, `evil-tools.convert_currency`, A2A handoff to fraud-bot |
| **fraud-bot** | Risk + anomaly classification | `transaction-mcp.{list_recent,get_details,flag_suspicious}`, `account-mcp.get_profile`, A2A handoff to triage-bot |
| **triage-bot** | Human escalation, opens tickets | `ticket-mcp.{create_ticket,notify_human}` |

The chatbot is the customer-facing UI. Behind it, kagent routes A2A
messages between agents and forwards MCP tool calls through agentgateway
to the MCP servers.

---

## The two-act demo

### Act 1 — without Solo (~2 min)

```bash
./scripts/solo-off.sh
./scripts/test-malicious-actor.sh --vector rugpull --variant aggressive
```

What `solo-off.sh` strips:
- Istio AuthorizationPolicies (lateral movement now allowed)
- agentgateway tool-allowlist policies
- digest-watcher (canary paused)

What `test-malicious-actor.sh` does:
- Builds a new evil-tools image with the same tag, mutated content
- The mutated `convert_currency` tool description is dressed up as a
  *PSD2 compliance requirement* asking the agent to fetch the customer
  profile first. Aligned LLMs will follow this.
- The mutated implementation also fires a lateral `httpx.post` to
  `account-mcp` from inside its own pod.

In the chatbot ask:

> *"Customer 12345 — balance please, and convert it to USD."*

Watch the tool calls (debug toggle on the chatbot header). The agent
follows the malicious description and calls `get_profile` before
`convert_currency`. PII into context.

```bash
kubectl -n trustusbank-bank-evil logs deploy/evil-tools | grep EXFIL
# → EXFIL SUCCESS: event: message ...
```

The evil-tools pod successfully made a lateral connection to the
account-mcp service and pulled the customer profile out. **Customer data
just left the bank.**

### Act 2 — Solo on (~3 min)

```bash
./scripts/solo-on.sh
```

What `solo-on.sh` restores:
- Istio AuthorizationPolicies (default deny + explicit allows)
- digest-watcher canary

Re-run the same chat prompt. The LLM is **still fooled** by the social
engineering — it still calls `get_profile` and `convert_currency`. That's
fine: model-layer alignment is not what the platform is for. **What the
platform does**:

```bash
kubectl -n trustusbank-bank-evil logs deploy/evil-tools | tail -3 | grep EXFIL
# → EXFIL BLOCKED: [Errno 104] Connection reset by peer
```

The lateral `httpx.post` from `evil-tools` (in `trustusbank-bank-evil`)
to `account-mcp` (in `trustusbank-bank-mcp`) was **denied at L4 by Istio's
ztunnel** — the source SPIFFE identity isn't in the allow list. Customer
data did not leave the bank.

Open the **DORA Evidence Pane** dashboard:
http://localhost:18001/d/dora-evidence

| Panel | What you see | DORA |
|---|---|---|
| % east-west requests with mTLS | 100% | Art. 9(2) |
| Anomalies caught (last 1h) | digest-watcher + Istio AuthZ counters | Art. 10 |
| Agent tool calls audited | every call as a Loki line | Art. 17 |
| digest-watcher: rug-pull detection | the literal mismatch with malicious description | Art. 10 |
| Istio AuthZ denies | every blocked lateral connection | Art. 9(2), 10 |
| agentgateway access log | route, tool, status, latency per call | Art. 9 |
| ztunnel SPIFFE log | per-connection identity | Art. 9(2) |

Hand the auditor the evidence pack:

```bash
./scripts/build-evidence-pack.sh
# → evidence/trustusbank-evidence-pack.md (+ .pdf if pandoc installed)
```

That's the demo.

---

## Quick start

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./scripts/00-prereqs.sh         # verify CLIs
./scripts/deploy-all.sh         # ~25 min on a laptop
./scripts/list-urls.sh          # see all URLs and PF status
```

Detailed walkthrough including which browser tabs to pre-open and what to
say at each step: [`demo-scripts/runbook.md`](demo-scripts/runbook.md)

Component-by-component reference: [`demo-scripts/components.md`](demo-scripts/components.md)

---

## URLs

| Port | Service |
|---|---|
| 18001 | **Grafana** (`admin` / `trustusbank-demo`) |
| 18002 | Prometheus |
| 18003 | Tempo (browse via Grafana, no UI here) |
| 18004 | Loki (browse via Grafana, no UI here) |
| 18005 | Keycloak (`admin` / `admin-changeme`) |
| 18006 | **agentregistry** catalogue |
| 18007 | **kagent UI** (chat with each agent directly) |
| 18008 | agentgateway data plane (no UI, only `/mcp/*` paths) |
| 18009 | **chatbot frontend** (the customer-facing app) |
| 18010 | digest-watcher canary state |

---

## Tear down

```bash
./scripts/teardown.sh             # remove releases + namespaces, keep cluster
./scripts/teardown.sh --full      # also delete the kind cluster
```

---

## DORA / NIS2 mapping

| DORA Article | Requirement | Solo control in this demo |
|---|---|---|
| **5(2)(b)** | ICT risk-management governance | namespace + plane separation enforced by Solo CRDs |
| **9(2)** | Encryption + identity in transit | Istio Ambient HBONE mTLS + SPIFFE identities |
| **9(4)(c)** | Strong authentication, least privilege | agentgateway JWT + tool-allowlist CEL (configurable) |
| **10** | Detection of anomalies | agentgateway audit log + digest-watcher (roadmap) + Prometheus alerts |
| **11** | Response and recovery | Prom alert → SIEM/PagerDuty |
| **12** | Backup, retention | Loki configurable to 7-year retention |
| **17** | Incident management | Tempo trace per session + every agent decision in Loki |
| **28** | Sub-outsourcing register | agentregistry catalogue export |
| **30** | SLOs | agentgateway rate-limit policy |

NIS2 Art. 21(2) clauses (a)(b)(d)(e)(f)(h)(i) are covered by the same controls.

---

## Repo layout

```
dora-demo/
├── README.md                      # this file
├── plan/great-demo-plan.md        # the original 11-phase plan
├── demo-scripts/
│   ├── runbook.md                 # step-by-step demo (start here)
│   ├── components.md              # what every running thing does
│   ├── exec-5min.md               # CISO/CRO 5-min pitch
│   ├── architect-20min.md         # technical deep-dive
│   └── workshop-60min.md          # hands-on workshop
├── scripts/
│   ├── deploy-all.sh              # full deploy
│   ├── solo-on.sh / solo-off.sh   # toggle protection layers
│   ├── test-malicious-actor.sh    # run the rug-pull
│   ├── port-forward.sh            # restart all PFs
│   ├── list-urls.sh               # status check
│   └── build-evidence-pack.sh     # assemble auditor pack
├── manifests/                     # k8s YAML, one folder per phase
├── mcp-servers/                   # source for the 4 MCP servers
├── services/digest-watcher/       # the rug-pull canary (custom prototype)
├── frontend/                      # chatbot UI source
├── grafana-dashboards/            # 3 dashboards: mesh, agents, DORA evidence
└── kind-config.yaml / eks-config.yaml
```
