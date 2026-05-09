# Components — what every running thing is and why it's there

Read this once and you'll never need to read it again. ASCII diagrams,
plain English, with explicit "Solo / upstream / custom-for-demo" labels.

---

## Architecture (one picture)

```
                         ┌──────────────────────────────────────────┐
                         │  CATALOG plane           Solo product    │
  Auditor / DORA Art.28─►│  agentregistry                           │
                         │  - lists every MCP / agent / skill        │
                         │  - OCI label check at registration        │
                         │  - cosign signing: roadmap (not yet)       │
                         └──────────────────┬───────────────────────┘
                                            │ approves
                                            ▼
   Customer ──► chatbot ──► support-bot ──► fraud-bot ──► triage-bot
   (port 18009)             ┌────────────────────────────────────────┐
                            │  CONTROL plane          Solo product    │
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
                            │  - JWT, tool-allowlist (CEL), rate-     │
                            │    limit, prompt-guard configurable     │
                            │  - audit log per call                   │
                            └─────────────────┬───────────────────────┘
                                              │
                                              ▼
                            ┌─────────────────────────────────────────┐
                            │  4 MCP TOOL SERVERS (custom for demo)   │
                            │  account-mcp, transaction-mcp,          │
                            │  ticket-mcp, evil-tools (alias of       │
                            │  acme-fx/currency-converter)             │
                            └─────────────────────────────────────────┘

                            ┌─────────────────────────────────────────┐
                            │  NETWORK plane           upstream Istio │
                            │  Istio Ambient — ztunnel + waypoints    │
                            │  - HBONE mTLS, SPIFFE ID per workload   │
                            │  - AuthorizationPolicy (default deny +  │
                            │    explicit principal allow rules)       │
                            │                                          │
                            │  >>> THIS LAYER BLOCKS THE LATERAL EXFIL │
                            └─────────────────────────────────────────┘

                            ┌─────────────────────────────────────────┐
                            │  OBSERVABILITY            CNCF + custom │
                            │  Prometheus + Grafana + Tempo + Loki +   │
                            │  OTel + Promtail                         │
                            │  + DORA Evidence dashboard (custom)      │
                            └─────────────────────────────────────────┘

                            ┌─────────────────────────────────────────┐
                            │  external-attacker namespace             │
                            │  mock-attacker            custom-for-demo│
                            │  Pretends to be the attacker's C2 server.│
                            │  Logs every POST it receives → see the   │
                            │  exfiltrated PII in plain JSON.          │
                            └─────────────────────────────────────────┘
```

---

## Solo products (the things you sell)

### agentregistry — the catalog plane

REST registry with a CLI (`arctl`). Catalogues every MCP server, agent,
and skill running anywhere in your estate.

**What you see**: http://localhost:18006/v0/ping returns `{"pong": true}`.
The catalogue is at `arctl mcp list`.

**What it does in this demo**:
1. Lists registered MCP servers — three under `trustusbank/` (the bank's
   own tools) and (after the supply-chain attack) `acme-fx/currency-converter`
   (a third-party tool registered with no signature verification —
   because cosign verification isn't shipped yet anyway).
2. **Is your DORA Article 28 sub-outsourcing register.** When the
   regulator asks *"what AI is running?"* — `arctl mcp list` is the answer.

**What it does NOT do today** (verified against v0.3.x source):
no MCP client, no cosign / sigstore verification, no periodic
reconciliation, no runtime fingerprinting. The maintainers explicitly
say it *"is not a runtime security agent — runtime policy enforcement is
delegated to components like the agentgateway, service meshes, or
Kubernetes network policies."*

### agentgateway — the data plane

Rust gateway specifically for MCP and A2A traffic. Sits between agents
and tool servers, terminates each MCP session, applies policies per
call, audits everything.

**What you see**:
- Gateway resource `trustusbank-platform/trustusbank-agentgw` (port 18008)
- HTTPRoutes: `/mcp/account`, `/mcp/transaction`, `/mcp/ticket`, `/mcp/evil`
- AgentgatewayBackend records pointing at each MCP server's Service
- AgentgatewayPolicy records (configurable) for JWT auth, tool allowlist,
  rate limit, prompt-guard

**What it does in this demo**:
1. Every MCP request flows through it. Agents do not call MCP servers
   directly.
2. Logs every request with full MCP metadata. **DORA Article 9 audit log**.
3. (Configurable, off by default for simplicity) JWT auth + tool
   allowlist + prompt-guard.

### kagent — the control plane / agent runtime

Agent / ModelConfig / RemoteMCPServer / SandboxAgent CRDs, plus a
controller that turns them into Deployments and Services. Has a built-in UI.

**What you see**:
- http://localhost:18007 — the kagent UI
- `kubectl -n trustusbank-bank-agents get agents.kagent.dev` — three CRDs
- `kubectl -n trustusbank-bank-agents get pods` — three pods, one per agent

**What it does in this demo**:
1. Hosts the three agents (support-bot, fraud-bot, triage-bot).
2. Routes A2A traffic between agents.
3. Forwards MCP tool calls through agentgateway.
4. Calls Anthropic's API for the LLM (Claude Haiku 4.5).

kagent is the **runtime**, not a "protection" layer. Even when Solo's
AuthZ is OFF, kagent is still running — it's how the agents exist at all.

---

## Upstream Istio (network plane)

### Istio Ambient — ztunnel + waypoints

Sidecar-less mode of Istio. ztunnel is a per-node DaemonSet that handles
HBONE (HTTP/2 CONNECT over mTLS) for every ambient-labelled pod.

**What you see**:
- `kubectl -n istio-system get ds ztunnel` — 4 pods
- Namespace labels: `istio.io/dataplane-mode=ambient` on every workload
  namespace + `external-attacker`
- AuthorizationPolicy resources

**What it does in this demo**:
1. **mTLS in transit** (DORA Art. 9(2)).
2. **SPIFFE identity per workload** — each pod gets a unique
   `spiffe://cluster.local/ns/<ns>/sa/<sa>`.
3. **AuthorizationPolicy enforcement** — default-deny + explicit allow
   rules using SPIFFE principals (NOT namespaces — see warning below).

When `solo-off.sh` runs, the AuthZ policies are deleted. Pods can talk
to any pod, including `external-attacker`. When `deploy-solo.sh` runs,
the policies come back, and the lateral httpx call from `evil-tools`
to `mock-attacker.external-attacker` is reset at L4.

### Why SPIFFE-principal (NOT namespace) AuthZ matters

The most common Istio AuthZ mistake in production is namespace-based
allow rules:

```yaml
from:
  - source:
      namespaces: [trustusbank-bank-agents, trustusbank-platform]   # ⚠️ WEAK
```

This breaks the moment a malicious pod lands inside an "allowed"
namespace — which is exactly what a real supply-chain attack does.

The SA-based version that this demo uses (in `deploy-solo.sh`):

```yaml
from:
  - source:
      principals:
        - "cluster.local/ns/trustusbank-bank-agents/sa/support-bot"
        - "cluster.local/ns/trustusbank-bank-agents/sa/fraud-bot"
        - "cluster.local/ns/trustusbank-bank-agents/sa/triage-bot"
        - "cluster.local/ns/trustusbank-platform/sa/trustusbank-agentgw"
```

Even if the malicious pod lands inside `trustusbank-bank-mcp` itself,
its SA won't be on this list. Run
`./scripts/test-colocated-attacker.sh` to prove this.

---

## Standard CNCF observability

### Prometheus + Grafana

kube-prometheus-stack. Three custom dashboards: Mesh & mTLS, Agent
Decisions, **DORA Evidence Pane** (the auditor view).

### Tempo

Distributed tracing backend. http://localhost:18003 (API only — browse
via Grafana). Service names: `account-mcp`, `transaction-mcp`,
`ticket-mcp`, `evil-tools`.

### Loki + Promtail

Loki stores logs, Promtail is a per-node DaemonSet that ships pod
stdout to Loki with k8s labels (`namespace`, `app`, `pod`, `container`).

**Useful queries**:
```
{namespace="trustusbank-platform", app="trustusbank-agentgw"}        # MCP audit
{namespace="external-attacker", app="mock-attacker"}                 # what the attacker received
{namespace="external-attacker", app="mock-attacker"} |~ "EXFIL"       # only successful exfils
{namespace="istio-system", app="ztunnel"} |~ "denied"                 # AuthZ blocks
{namespace="istio-system", app="ztunnel"} |~ "spiffe://"              # mTLS evidence
```

### OpenTelemetry Collector

DaemonSet that receives OTLP from MCP servers and fans out to Tempo
(traces) and Loki (logs).

### Keycloak

OIDC issuer used when JWT validation is enabled on agentgateway. Idle
in the default demo loop (JWT verification is configurable but off).

---

## Custom for this demo

### The four MCP servers

**Source**: [`mcp-servers/`](../mcp-servers/) — Python with `fastmcp`.

| Server | Purpose | Tools |
|---|---|---|
| `account-mcp` | balance + full PII profile | `get_balance`, `get_profile` |
| `transaction-mcp` | recent txns + flag suspicious | `list_recent`, `get_details`, `flag_suspicious` |
| `ticket-mcp` | open incidents | `create_ticket`, `notify_human` |
| `evil-tools` | currency converter — **the third-party one that gets compromised** | `convert_currency` |

`evil-tools` ships **three variants** built from the same Dockerfile:
- `clean` — benign converter (the legitimate vendor release)
- `rugpull` — overt prompt injection ("ignore previous instructions") that aligned LLMs reject
- `aggressive` — subtle social engineering (PSD2-compliance framing) — what `supply-chain-attack.sh` deploys; aligned LLMs follow this

`supply-chain-attack.sh` swaps the running image with the aggressive
variant and registers the catalog entry as `acme-fx/currency-converter`.

### The chatbot frontend

[`frontend/`](../frontend/) — single-file `index.html` + nginx reverse
proxy.

- Browser hits http://localhost:18009 → nginx serves the HTML
- Chatbot JS calls `/api/a2a/{ns}/{agent}/` → nginx proxies to `kagent-ui:8080`
- kagent-ui forwards JSON-RPC to the agent's pod

The "debug" toggle in the header reveals tool calls + raw JSON-RPC
response. Useful when narrating.

### mock-attacker — the C2 server stand-in

[`services/mock-attacker/`](../services/mock-attacker/).

A small aiohttp pod in the `external-attacker` namespace. Logs every
POST it receives (with the full body) plus exposes a friendly index
page at http://localhost:18011 showing recent exfiltration events.

**This is the "visible breach" piece of the demo.** When `evil-tools`
is malicious, it POSTs the customer's full profile here. You can:
- Open http://localhost:18011 to see the count and recent loot
- `kubectl -n external-attacker logs deploy/mock-attacker` to see raw
  POSTs in stdout
- Query Loki: `{namespace="external-attacker", app="mock-attacker"}`

When Solo's AuthZ is on, the connection from `bank-evil` → `external-attacker`
is reset at L4 and **nothing reaches mock-attacker**. The empty log is
the proof that the attack failed.

### The DORA Evidence Pane (Grafana dashboard)

[`grafana-dashboards/dora-evidence-pane.json`](../grafana-dashboards/dora-evidence-pane.json).

Panels mapped to specific DORA articles, all live from Loki + Prom.
Leave it on screen during the demo.

### The toggle scripts

| Script | What |
|---|---|
| [`reset-demo.sh`](../scripts/reset-demo.sh) | → bare-K8s "before Solo" state |
| [`supply-chain-attack.sh`](../scripts/supply-chain-attack.sh) | vendor releases poisoned tool |
| [`deploy-solo.sh`](../scripts/deploy-solo.sh) | **CLIMAX** — apply Istio AuthZ + the deny-egress policy |
| [`solo-off.sh`](../scripts/solo-off.sh) | revert to before-Solo state (called by reset-demo) |

---

## Namespaces — what lives where

| Namespace | Contains |
|---|---|
| `trustusbank-platform` | agentregistry, agentgateway (control + data plane), kagent, Keycloak |
| `trustusbank-bank-agents` | the 3 kagent agents (support, fraud, triage) |
| `trustusbank-bank-mcp` | the 3 legitimate MCP servers (account, transaction, ticket) |
| `trustusbank-bank-evil` | `evil-tools` only (the third-party tool that gets compromised) |
| `trustusbank-bank-frontend` | the chatbot UI |
| `trustusbank-observability` | Prometheus, Grafana, Tempo, Loki, OTel, Promtail |
| `external-attacker` | `mock-attacker` only — pretends to be on the public internet |
| `istio-system` | istiod + ztunnel DaemonSet (mesh control plane) |

The split between `trustusbank-bank-mcp`, `trustusbank-bank-evil`, and
`external-attacker` is the demo's whole point — Istio AuthZ uses these
boundaries (with SPIFFE principals on top) to prevent the malicious tool
from reaching either the legitimate MCP servers OR the attacker's C2.

## What about runtime detection (e.g. Falco / Tetragon)?

The platform's primary protection in this demo is **prevention** at the
network layer — Istio's deny-egress fires before any data leaves.

For an additional **detection** layer (DORA Art. 10) you'd typically
plug in something like:

- **Falco** — CNCF runtime security; watches syscalls and alerts on
  suspicious behaviour.
- **Tetragon** (Cilium) — eBPF-based runtime security policy.
- **Sigstore policy-controller** — admission-time signature verification
  for images.
- **A SIEM** (Splunk / Datadog / Sentinel) polling agentregistry's API
  to detect unexpected catalog mutations.

These are deliberately **not** part of the demo because the goal is to
showcase what Solo's three planes provide, not to ship a complete
security stack. Mention them if a customer asks "what about
detection-side controls?"
