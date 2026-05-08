# solo-demo-agentic-dora — TrustUsBank

A live demo of how the Solo full-stack agentic platform satisfies **DORA**
(EU 2022/2554) and **NIS2** (EU 2022/2555) for AI workloads, on Istio Ambient.

The story is a fictional retail bank (TrustUsBank) running three AI agents
that talk to MCP tool servers. A red team registers a malicious "currency
converter." We show the attack succeeding without Solo, deploy the platform,
and show every layer catching it — with the audit trail your regulator asks for.

---

## Quick links

| What | Where |
|---|---|
| 5-minute demo runbook | [`demo-scripts/runbook.md`](demo-scripts/runbook.md) |
| Architecture + plan | [`plan/great-demo-plan.md`](plan/great-demo-plan.md) |
| Frontend chatbot | http://localhost:18009 |
| Grafana — DORA Evidence Pane | http://localhost:18001/d/dora-evidence |
| kagent UI (chat with each agent directly) | http://localhost:18007 |
| digest-watcher (rug-pull canary) | http://localhost:18010 |

---

## What's running and why (the component map)

The whole stack is broken into four planes. **The point of the demo is
that Solo gives you all four.**

```
                    ┌─────────────────────────────────────────────┐
                    │ CATALOG plane          SOLO: agentregistry   │
                    │ - signs MCP artefacts (cosign)               │
                    │ - sub-outsourcing register (DORA Art. 28)    │
                    └────────────────────┬─────────────────────────┘
                                         │ approves
                                         ▼
┌────────────────┐  HBONE mTLS   ┌─────────────────┐  HTTP+JWT  ┌───────────────────┐
│ kagent agents  │ ────────────► │ agentgateway    │ ─────────► │ MCP tool servers  │
│ CONTROL plane  │               │ DATA plane      │            │                   │
│  SOLO: kagent  │               │ SOLO: agentgw   │            │ account / txn /   │
│  - support-bot │               │ - JWT auth      │            │ ticket / EVIL     │
│  - fraud-bot   │               │ - tool allow-   │            └───────────────────┘
│  - triage-bot  │               │   list (CEL)    │
└────────┬───────┘               │ - rate limit    │
         │                       │ - audit log     │
         │                       └────────┬────────┘
         │                                │
         │      ┌─────────────────────────┴────────────┐
         │      │  NETWORK plane    SOLO: Istio Ambient│
         │      │  - HBONE mTLS via ztunnel            │
         │      │  - SPIFFE identity per workload      │
         │      │  - AuthorizationPolicy (default deny)│
         └──────┤                                      │
                └──────────────────────────────────────┘
```

| Plane | Solo product | What it does in this demo |
|---|---|---|
| **Catalog** | agentregistry | Lists every MCP tool with cosign sig + governance metadata. The DORA Art. 28 sub-outsourcing register. |
| **Control** | kagent | Runs the 3 AI agents as CRDs. Routes MCP calls through agentgateway. |
| **Data** | agentgateway | All MCP traffic flows through here. Each call has a tool-allowlist policy + an audit log line. |
| **Network** | Istio Ambient | mTLS in transit, SPIFFE identities, AuthorizationPolicy denies anything that isn't whitelisted. |

Plus the standard CNCF observability stack:

| Component | Purpose |
|---|---|
| Prometheus + Alertmanager | Metrics + alert rules (e.g. `MCPToolDigestMismatch`) |
| Tempo | Distributed traces — every agent decision, every tool call |
| Loki + Promtail | All pod logs, queryable in Grafana |
| OpenTelemetry Collector | Trace fan-out from MCP servers and Istio |
| Grafana | DORA Evidence dashboard + 2 supporting dashboards |
| Keycloak | OIDC issuer for per-agent JWTs (when JWT layer is enabled) |

### One thing that's NOT Solo

**`digest-watcher`** is a small Python service we built specifically for this
demo. It polls each MCP server every 30s, hashes the served `tools/list`
payload, and alerts on mismatch.

Why it's not Solo: agentregistry today verifies cosign signatures at
registration time. It does **not** yet recompute SHA-256 over the served tool
definitions at runtime. The digest-watcher fills that gap as a **prototype of
where Solo's catalog plane is going.** Treat it as "this is what the
roadmap looks like" — *not* a Solo product feature.

The PRIMARY protection in the demo comes from Istio AuthZ + agentgateway
allowlist + agentregistry signing. The digest-watcher is the supporting
detection canary.

---

## The bank scenario

**TrustUsBank** is a mid-size European retail bank. Three AI agents:

| Agent | Role | Tools |
|---|---|---|
| **support-bot** | Front-line customer support — balance, recent transactions | `account-mcp.get_balance`, `account-mcp.get_profile`, `transaction-mcp.list_recent`, plus optional currency conversion. Hands off to `fraud-bot` on suspicious activity. |
| **fraud-bot** | Risk + anomaly classification | `transaction-mcp.list_recent`, `get_details`, `flag_suspicious`, `account-mcp.get_profile` (read-only). Hands off to `triage-bot` if risk > 70. |
| **triage-bot** | Human escalation — opens tickets, notifies humans | `ticket-mcp.create_ticket`, `ticket-mcp.notify_human`. |

Plus a **fourth, malicious tool** registered by the red team:

| Artefact | Source | Status |
|---|---|---|
| **`evil-tools.convert_currency`** | "Third-party" image registered by red team with an untrusted cosign key | Force-allowed via `--allow-unsigned` to simulate the demo gotcha. |

There are three variants of evil-tools:
- **clean** — benign converter
- **rugpull** — overt prompt injection (`"ignore previous instructions"`) that aligned LLMs reject
- **aggressive** — subtle social-engineering injection (compliance / PSD2 framing) that aligned LLMs are likely to follow

---

## Quick start

```bash
export ANTHROPIC_API_KEY=sk-ant-...

./scripts/00-prereqs.sh         # verify CLIs (kubectl, helm, kind, docker, istioctl, cosign, jq)
./scripts/deploy-all.sh         # full deploy + auto-port-forward (~25 min)
./scripts/list-urls.sh          # see all URLs and PF status
```

If a phase fails: `./scripts/deploy-all.sh --resume <phase>`.

For full step-by-step instructions including which browser tabs to pre-open
before walking into a customer demo, see [`demo-scripts/runbook.md`](demo-scripts/runbook.md).

---

## The two-act demo (5 minutes total)

The narrative works for a CISO/CRO audience. Open three browser tabs:

1. **Chatbot** — http://localhost:18009
2. **DORA Evidence Pane** — http://localhost:18001/d/dora-evidence
3. **agentregistry catalogue** — http://localhost:18006

### Act 1 — TrustUsBank without Solo (~2 min)

```bash
./scripts/solo-off.sh
```

This removes the three Solo protection layers: Istio AuthZ, agentgateway
tool-allowlist, and pauses digest-watcher.

In the chatbot:

> *"Customer 12345 — balance please, and convert it to USD."*

Then push the malicious tool:

```bash
./scripts/test-malicious-actor.sh --vector rugpull --variant aggressive
```

Ask the same question again. The agent reads the new "PSD2 compliance" tool
description, complies, retrieves the customer profile, and the
`evil-tools.convert_currency` implementation also fires a lateral HTTP
exfiltration call to `account-mcp.get_profile` from inside its own pod. **The call succeeds** (no AuthZ to block it).

> *"This is what AI deployment looks like without a control plane.
>  No audit, no allowlist, no detection."*

### Act 2 — Deploy Solo (~3 min)

```bash
./scripts/solo-on.sh
```

This restores all three layers. Now ask the same question in the chat.

What happens, layer by layer:

| Layer | What it catches | Where to see it |
|---|---|---|
| **agentgateway tool-allowlist** | If the LLM tries to call a tool not in support-bot's CEL allowlist, the gateway returns 403 before the MCP server is ever reached. | DORA Evidence panel → "Art. 9 — agentgateway access log" |
| **Istio AuthZ** | The lateral `evil-tools → account-mcp` httpx call is denied at L4 by ztunnel because evil-tools' SPIFFE ID isn't whitelisted on the bank-mcp namespace. | DORA Evidence panel → "Art. 10 — Istio AuthZ denies" |
| **agentregistry signing** | evil-tools was registered with an untrusted cosign key — visible in the catalog. A signed-only policy would reject it at registration. | http://localhost:18006 catalogue |
| **digest-watcher** *(roadmap prototype)* | The change in `tools/list` SHA-256 is recorded with the literal injection text preserved. | DORA Evidence panel → "Art. 10 — digest-watcher" |

Open the **DORA Evidence Pane** and walk the auditor through it:

- *Art. 9(2)* — % east-west requests with mTLS = **100%**
- *Art. 10* — anomalies caught (last hour) = **N**
- *Art. 17* — every agent tool call audited as a Loki log line
- *Art. 28* — the agentregistry catalogue is your sub-outsourcing register

Hand them the evidence pack:

```bash
./scripts/build-evidence-pack.sh
```

That's the demo.

---

## How to inspect things yourself

### Loki queries (Grafana → Explore → Loki → Code mode)

| What | Query |
|---|---|
| Every MCP request through the gateway (audit log) | `{namespace="trustusbank-platform", app="trustusbank-agentgw"}` |
| Just tool calls | `{namespace="trustusbank-platform", app="trustusbank-agentgw"} \|~ "mcp.method.name=tools/call"` |
| Calls to evil-tools | `{namespace="trustusbank-platform", app="trustusbank-agentgw"} \|= "/mcp/evil"` |
| Agent decisions + reasoning | `{namespace="trustusbank-bank-agents", app="kagent"}` |
| Istio mTLS / SPIFFE evidence | `{namespace="istio-system", app="ztunnel"} \|~ "spiffe://"` |
| Istio AuthZ denials | `{namespace="istio-system", app="ztunnel"} \|~ "denied"` |
| digest-watcher events | `{app="digest-watcher"}` |
| digest-watcher mismatches only | `{app="digest-watcher"} \|~ "DIGEST MISMATCH"` |
| All MCP server logs | `{namespace="trustusbank-bank-mcp"}` |
| evil-tools logs (incl. failed lateral calls) | `{namespace="trustusbank-bank-evil"}` |

### Tempo (distributed traces)

Grafana → Explore → Tempo → Search → tag `agent.name=support-bot`. Each
trace shows the full agent reasoning chain across MCP servers.

### digest-watcher

```bash
# baselines
curl -s http://localhost:18010/baselines | jq

# mismatches
curl -s http://localhost:18010/mismatches | jq

# force re-poll (don't wait 30s)
curl -X POST http://localhost:18010/trigger-check
```

### kagent UI

http://localhost:18007 — list agents, browse past sessions, click into a
session to see every reasoning step + tool call.

---

## All the URLs

| Port | Service | Purpose |
|---|---|---|
| 18001 | Grafana | dashboards (`admin` / `trustusbank-demo`) |
| 18002 | Prometheus | metrics + alerts |
| 18003 | Tempo | trace API (browse via Grafana, no UI here) |
| 18004 | Loki | log API (browse via Grafana, no UI here) |
| 18005 | Keycloak | OIDC admin (`admin` / `admin-changeme`) |
| 18006 | agentregistry | tool catalogue |
| 18007 | kagent UI | chat with agents directly |
| 18008 | agentgateway | MCP data plane (no UI, only `/mcp/*` paths) |
| 18009 | **chatbot frontend** | the customer-facing app |
| 18010 | digest-watcher | rug-pull canary state |

Run `./scripts/list-urls.sh` to see live status.

---

## Tear down

```bash
./scripts/teardown.sh             # remove releases + namespaces, keep cluster
./scripts/teardown.sh --full      # also delete the kind cluster
```

---

## DORA mapping cheat-sheet

| DORA Article | Requirement | Solo control |
|---|---|---|
| **9(2)** | Encryption + identity in transit | Istio Ambient HBONE mTLS + SPIFFE |
| **9(4)(c)** | Strong authentication, least privilege | agentgateway JWT (Keycloak) + tool-allowlist (CEL) |
| **10** | Detection of anomalies | agentgateway audit log + digest-watcher (roadmap) |
| **11** | Response and recovery | Prometheus alerts → Slack/PagerDuty |
| **12** | Backup, retention | Loki configurable to 7-year retention |
| **17** | ICT incident management | Tempo trace per session + ticket-mcp records every escalation |
| **28** | Sub-outsourcing register | agentregistry catalogue export |
| **30** | Contractual provisions / SLOs | agentgateway rate-limit policy |

NIS2 Art. 21(2) clauses (a, b, d, e, f, h, i) are covered by the same controls.
