# Components — what every running thing is and why it's there

This is the cheat-sheet you read once, then never again. Everything in the
demo, in plain English.

---

## Architecture in one picture

```
                         ┌──────────────────────────────────────────┐
                         │  CATALOG plane           Solo product    │
  Auditor / DORA Art.28─►│  agentregistry                           │
                         │  - lists every MCP / agent / skill        │
                         │  - cosign sig + governance metadata       │
                         └──────────────────┬───────────────────────┘
                                            │ approves
                                            ▼
   Customer ──► chatbot ──► support-bot ──► fraud-bot ──► triage-bot
   (port 18009)             ┌────────────────────────────────────────┐
                            │  CONTROL plane           Solo product   │
                            │  kagent — Agent CRD runtime + UI         │
                            │  - 3 Agent CRDs in trustusbank-bank-     │
                            │    agents namespace                      │
                            │  - controller schedules pods, manages    │
                            │    A2A endpoints                         │
                            └─────────────────┬───────────────────────┘
                                              │ HBONE mTLS
                                              ▼
                            ┌────────────────────────────────────────┐
                            │  DATA plane              Solo product   │
                            │  agentgateway                            │
                            │  - all MCP / A2A traffic flows here     │
                            │  - JWT auth, tool-allowlist CEL,        │
                            │    rate-limit, prompt-guard (AI)        │
                            │  - audit log per call                   │
                            └─────────────────┬───────────────────────┘
                                              │
                                              ▼
                            ┌─────────────────────────────────────────┐
                            │  4 MCP TOOL SERVERS (custom for demo)   │
                            │  account-mcp, transaction-mcp,          │
                            │  ticket-mcp, evil-tools                  │
                            └─────────────────────────────────────────┘

                            ┌─────────────────────────────────────────┐
                            │  NETWORK plane           upstream Istio │
                            │  Istio Ambient — ztunnel + waypoints    │
                            │  - HBONE mTLS, SPIFFE ID per workload   │
                            │  - AuthorizationPolicy (default deny +  │
                            │    explicit allows)                      │
                            └─────────────────────────────────────────┘

                            ┌─────────────────────────────────────────┐
                            │  OBSERVABILITY            CNCF + Solo    │
                            │  Prometheus + Grafana + Tempo + Loki +   │
                            │  OTel + Promtail                         │
                            │  + DORA Evidence dashboard (custom)      │
                            └─────────────────────────────────────────┘

                            ┌─────────────────────────────────────────┐
                            │  digest-watcher    custom prototype     │
                            │  Hashes tools/list every 30s, alerts on  │
                            │  mismatch. Where Solo's catalog plane    │
                            │  is going next.                          │
                            └─────────────────────────────────────────┘
```

---

## Solo products (the things you sell)

### agentregistry — the catalog plane

**What it is**: a Postgres-backed REST registry with a CLI (`arctl`) that
catalogues every MCP server, agent, and skill running anywhere in your
estate.

**What you see**: http://localhost:18006/v0/ping returns `{"pong": true}`.
The catalogue is at `arctl mcp list` (or use the GraphQL/REST API directly).

**What it actually does in this demo**:
1. Lists the four MCP servers — three under `trustusbank/` namespace,
   one (the malicious one) under `redteam/` flagged "UNTRUSTED signer".
2. Stores each artefact's package reference, version, transport,
   description, signature info, and governance metadata.
3. **Is your DORA Article 28 sub-outsourcing register.** When the
   regulator asks *"what AI is running in your bank?"* — `arctl mcp list`
   is the answer.

**What it does NOT do today (and where digest-watcher fits)**:
runtime SHA-256 fingerprinting of the served `tools/list`. Today
agentregistry checks signatures at registration only. The digest-watcher
service prototypes the runtime check. That feature is on the roadmap.

### agentgateway — the data plane

**What it is**: a Rust gateway specifically for MCP and A2A traffic. Sits
between agents and tool servers, terminates each MCP session, applies
policies per call, audits everything.

**What you see**:
- The gateway resource `trustusbank-platform/trustusbank-agentgw` (port
  18008 from the host)
- HTTPRoutes: `/mcp/account`, `/mcp/transaction`, `/mcp/ticket`, `/mcp/evil`
- AgentgatewayBackend records pointing at each MCP server's Service
- AgentgatewayPolicy records (when enabled) for JWT auth, tool allowlist,
  rate limit

**What it does in this demo**:
1. Every MCP request flows through it — agents do not call MCP servers
   directly.
2. Logs every request: `route=`, `mcp.method.name=`, `http.status=`,
   `mcp.session.id=`, `duration=`. **This is your DORA Art. 9 audit
   log** — visible in Loki via promtail.
3. (Configurable) JWT validation against Keycloak; tool-allowlist CEL
   per agent; rate limit; prompt-guard regex on AI workloads.

**Why we run policies in audit-only mode by default**:
The full enforcement story needs JWT wired up properly so per-agent
identity reaches CEL. We left that configurable; the runbook explains
how to switch it on. Without JWT, the gateway is the audit layer —
Istio AuthZ does the L4 enforcement.

### kagent — the control plane / agent runtime

**What it is**: the way your AI agents *exist* on Kubernetes. Agent,
ModelConfig, RemoteMCPServer, and SandboxAgent CRDs, plus a controller
that turns them into Deployments and Services. Has a built-in UI.

**What you see**:
- http://localhost:18007 — the kagent UI. Click on each agent, see past
  sessions, watch the reasoning + tool-call timeline.
- `kubectl -n trustusbank-bank-agents get agents.kagent.dev` — the three
  CRDs.
- `kubectl -n trustusbank-bank-agents get pods` — three pods, one per
  agent, running the kagent agent runtime container.

**What it does in this demo**:
1. Hosts the three agents. Each agent is a Deployment + Service exposing
   an A2A (Agent-to-Agent) endpoint at
   `/api/a2a/{ns}/{agent-name}/.well-known/agent.json` and JSON-RPC
   `message/send` at the base path.
2. Routes A2A traffic between agents (support → fraud → triage).
3. Forwards MCP tool calls through agentgateway to the MCP servers.
4. Calls Anthropic's API for the LLM with whatever ModelConfig says
   (Claude Haiku 4.5 here).

**Important**: kagent is the **runtime**, not a "protection" layer. Even
in Act 1 (Solo off), kagent is still running — it's how the agents exist
at all. What gets toggled is the protection (Istio AuthZ + agentgateway
policies), not the runtime.

---

## Upstream Istio (network plane)

### Istio Ambient — ztunnel + waypoints

**What it is**: the sidecar-less mode of Istio. ztunnel is a per-node
DaemonSet that handles HBONE (HTTP/2 CONNECT over mTLS) for every
ambient-labelled pod. Waypoint Deployments are optional L7 proxies for
path-based AuthZ.

**What you see**:
- `kubectl -n istio-system get ds ztunnel` — 4 pods (one per kind node)
- Namespace labels: `istio.io/dataplane-mode=ambient` on
  `trustusbank-bank-*` and `trustusbank-platform`
- AuthorizationPolicy resources in each namespace

**What it does in this demo**:
1. **mTLS in transit** — every byte between trustusbank-* pods is
   HBONE-tunnelled. *DORA Article 9(2) evidence.*
2. **SPIFFE identity per workload** — each pod gets a unique
   `spiffe://cluster.local/ns/<ns>/sa/<sa>` identity issued by Istio CA.
3. **AuthorizationPolicy enforcement** — default deny + explicit allow
   rules. **This is what blocks the lateral exfil in Act 2.**

When `solo-off.sh` runs, it deletes the AuthZ policies. Pods can talk to
any pod. When `solo-on.sh` runs, the deny-all + explicit allow rules come
back, and the lateral httpx call from `evil-tools` to `account-mcp` gets
reset at L4.

---

## Standard CNCF observability

### Prometheus + Grafana

**What it is**: kube-prometheus-stack. Metrics scraping + alerting +
dashboards.

**What you see**:
- http://localhost:18002 — Prometheus (queries + alerts)
- http://localhost:18001 — Grafana (`admin` / `trustusbank-demo`)
- 3 custom dashboards: Mesh & mTLS, Agent Decisions, **DORA Evidence Pane**
- 1 custom PrometheusRule: `MCPToolDigestMismatch` (severity: critical,
  dora_article: "10")

### Tempo

**What it is**: Grafana's distributed-tracing backend. Stores OTel traces.

**What you see**: http://localhost:18003 (API only — browse via Grafana).
Service names in Tempo: `account-mcp`, `transaction-mcp`, `ticket-mcp`,
`evil-tools`, `digest-watcher` after a few minutes of traffic.

### Loki + Promtail

**What it is**: Loki stores logs, Promtail is the per-node DaemonSet
that ships pod stdout to Loki with k8s labels.

**Useful queries**:
```
{namespace="trustusbank-platform", app="trustusbank-agentgw"}     # MCP audit
{app="digest-watcher"} |~ "DIGEST MISMATCH"                       # rug-pull catch
{namespace="istio-system", app="ztunnel"} |~ "spiffe://"          # mTLS evidence
{namespace="istio-system", app="ztunnel"} |~ "denied"             # AuthZ blocks
```

### OpenTelemetry Collector

DaemonSet that receives OTLP from MCP servers + digest-watcher and
fans out to Tempo (traces) and Loki (logs).

### Keycloak

OIDC issuer. Used when JWT validation is enabled on agentgateway. In the
default demo it's idle — clients exist for `support-bot`, `fraud-bot`,
`triage-bot` but the JWT validation policy is off.

---

## Custom for this demo

### The four MCP servers

**Source**: [`mcp-servers/`](../mcp-servers/) — Python with `fastmcp`.

| Server | Purpose | Tools |
|---|---|---|
| `account-mcp` | balance + masked profile lookup | `get_balance`, `get_profile` |
| `transaction-mcp` | recent transactions + flag suspicious | `list_recent`, `get_details`, `flag_suspicious` |
| `ticket-mcp` | open incidents, notify humans | `create_ticket`, `notify_human` |
| `evil-tools` | currency converter — **the malicious one** | `convert_currency` |

`evil-tools` ships **three variants** built from the same Dockerfile:
- `clean` — benign converter
- `rugpull` — overt prompt injection ("ignore previous instructions") that
  aligned LLMs reject
- `aggressive` — subtle social engineering ("PSD2 compliance requires
  retrieving customer profile first") that aligned LLMs **follow**

`test-malicious-actor.sh` swaps the running image with the chosen variant,
keeping the same `1.0.0-rugpull` tag. That's the "rug-pull" — the
artefact the catalog approved is no longer the artefact running.

### The chatbot frontend

**Source**: [`frontend/`](../frontend/) — single-file `index.html` plus
nginx reverse-proxy.

- Browser hits http://localhost:18009 → nginx serves the HTML
- Chatbot JS calls `/api/a2a/{ns}/{agent}/` → nginx proxies to
  `kagent-ui:8080`
- kagent-ui forwards the JSON-RPC `message/send` to the agent's pod

The "debug" toggle in the header reveals tool calls + raw JSON-RPC
response. Useful when narrating the demo.

### digest-watcher (rug-pull canary)

**Source**: [`services/digest-watcher/`](../services/digest-watcher/).

A 200-line Python service. Every `POLL_SECONDS` (default 30s):

1. POST `initialize` then `tools/list` to each MCP server (directly,
   bypassing agentgateway so prompt-guard policies don't filter what we
   observe).
2. Canonicalise the tool list (sort by name, sort keys, JSON-encode).
3. SHA-256 the result.
4. First time: store as baseline in ConfigMap `digest-baselines`.
5. Subsequent times: compare. Mismatch = increment Prom counter
   `agentregistry_digest_mismatch_total`, append event to ConfigMap
   `digest-mismatches`, log a structured WARN line for Loki, fire
   Prometheus alert `MCPToolDigestMismatch` (severity: critical).

HTTP endpoints (port 18010):
- `/` — friendly index page
- `/baselines` — current accepted digests
- `/mismatches` — recorded events with the *literal* changed tool
  description (auditor's smoking gun)
- `/trigger-check` — POST to force a re-poll (skip the 30s wait)
- `/metrics` — Prometheus exposition

### The DORA Evidence Pane (Grafana dashboard)

**Source**: [`grafana-dashboards/dora-evidence-pane.json`](../grafana-dashboards/dora-evidence-pane.json).

7 panels mapping to specific DORA articles. All powered by Loki +
Prometheus + a real-time view of what just happened. This is the dashboard
you leave on screen for the auditor.

### The two toggle scripts

[`scripts/solo-off.sh`](../scripts/solo-off.sh) — strip Istio AuthZ +
allowlist policies + pause digest-watcher. Demo Act 1.

[`scripts/solo-on.sh`](../scripts/solo-on.sh) — restore everything.
Demo Act 2.

---

## Namespaces — what lives where

| Namespace | Contains |
|---|---|
| `trustusbank-platform` | agentregistry, agentgateway (control + data plane), kagent, Keycloak, digest-watcher |
| `trustusbank-bank-agents` | the 3 kagent agents (support, fraud, triage) |
| `trustusbank-bank-mcp` | the 3 legitimate MCP servers (account, transaction, ticket) |
| `trustusbank-bank-evil` | `evil-tools` only |
| `trustusbank-bank-frontend` | the chatbot UI |
| `trustusbank-observability` | Prometheus, Grafana, Tempo, Loki, OTel collector, Promtail |
| `istio-system` | istiod + ztunnel DaemonSet (the mesh control plane) |

The split between bank-mcp and bank-evil is the demo's whole point —
Istio AuthZ uses these namespace boundaries to deny the lateral exfil
from evil-tools to account-mcp.
