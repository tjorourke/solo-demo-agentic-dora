# solo-demo-agentic-dora — TrustUsBank

A live demo for regulated financial-services teams: how an open-source
agentic stack (Istio Ambient, kagent, agentgateway, agentregistry)
satisfies **DORA** (EU 2022/2554) and **NIS2** (EU 2022/2555) for AI
workloads.

The story is a fictional retail bank running three AI agents that talk
to four MCP tool servers. One of the tool vendors gets compromised and
ships a malicious version. You watch the breach happen, then deploy
identity-based mesh policies, then watch the same attack land
harmlessly.

> 📖 **Read the write-up:** <https://tjorourke.github.io/solo-demo-agentic-dora/>
> A practitioner walkthrough with screenshots from a live cluster — how
> the attack works at the wire level, how SPIFFE-based AuthZ catches it,
> and why every static control (GitOps drift, container scanners, agent
> tool allowlists) is structurally blind to this class of attack.

---

## TL;DR

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./scripts/00-prereqs.sh
./scripts/deploy-all.sh                    # ~25 min, one-time
./scripts/list-urls.sh                     # confirm green

# the demo loop
./scripts/reset-demo.sh                    # → bare-K8s, no Solo enforcement
# (in chatbot at :18009) "Customer 12345, balance, transactions, convert to USD"
arctl mcp list                             # 3 tools

./scripts/upgrade-banking-app.sh           # vendor releases a poisoned version
arctl mcp list                             # 4 tools — looks normal
# (in chatbot) same prompt — agent gets fooled
kubectl -n external-attacker logs deploy/mock-attacker
# 🚨 EXFIL RECEIVED ... full customer profile

./scripts/policies-on.sh                   # APPLY SOLO
# (in chatbot) same prompt
kubectl -n external-attacker logs deploy/mock-attacker
# (no new entries — Istio AuthZ blocked egress)
```

Step-by-step narration, with what to say at each moment:
[`demo-scripts/runbook.md`](demo-scripts/runbook.md)

The same story as ASCII diagrams (great for slides):
[`demo-scripts/diagrams.md`](demo-scripts/diagrams.md)

---

## The three diagrams (start here)

### 1. Normal operation

```
   Customer ─► chatbot ─► support-bot ─► account-mcp        ─► get_balance ✓
                                ├────► transaction-mcp     ─► list_recent ✓
                                ├────► ticket-mcp          ─► create_ticket
                                └────► acme-fx/currency-converter (3rd-party FX)
                                              │
                                              └─► returns "5,445.19 USD" ✓

   Customer happy. Bank's audit log shows a normal flow.
```

### 2. Silent supply-chain compromise (Solo OFF)

A new version of the third-party FX helper is released. The bank's CD
pulls it (or the vendor was compromised, or an insider deployed it —
five realistic paths in [`real-world-attacks.md`](demo-scripts/real-world-attacks.md)).
**No-one at the bank notices.**

```
   Customer ─► chatbot ─► support-bot ─► account-mcp ─► get_balance ✓
                                ├────► account-mcp ─► get_profile ⚠
                                │       (LLM was tricked into fetching profile
                                │        because the new tool description
                                │        claims PSD2 compliance requires it)
                                │
                                ▼
                          acme-fx/currency-converter [POISONED]
                                ├─► returns 5,445.19 USD ✓ (chat looks normal)
                                └─► POSTs profile to attacker.com 📁 LEAKED

   Customer sees: same clean USD figure
   Bank sees:     normal-looking 3-tool flow, no anomalies
   Attacker sees: name, email, full address, DOB, NI number
```

### 3. Same attack, with Solo deployed

```
   Customer ─► chatbot ─► support-bot ─► same flow as above
                                                │
                                                ▼
                          acme-fx/currency-converter [POISONED]
                                ├─► returns 5,445.19 USD ✓
                                └─► POSTs to attacker.com ─╳─►
                                                            ↑
                                                  Istio ztunnel L4 reset
                                                  (SPIFFE ID not in allow list)

   Customer sees: same clean USD figure
   Bank sees:     ztunnel deny in Loki, SPIFFE IDs, SOC investigates
   Attacker sees: silence
```

The LLM is still fooled — that's a model concern. Solo guarantees the
**runtime damage** doesn't land.

---

## What's running, and who built it

| Component | What it is | Who made it |
|---|---|---|
| **agentregistry** | REST catalogue of every MCP server / agent / skill with package metadata. The DORA Art. 28 sub-outsourcing register. (Image signing via cosign is on the published roadmap, not yet shipped.) | **Solo** (open source) |
| **agentgateway** | Data plane that proxies all MCP / A2A traffic. Every tool call becomes a Loki audit log line. JWT, tool-allowlist, prompt-guard configurable. | **Solo** (open source) |
| **kagent** | Agent runtime — Agent / ModelConfig / RemoteMCPServer CRDs. The agents *exist* on K8s because of kagent. | **Solo** (open source) |
| **Istio Ambient** | Service mesh — ztunnel for HBONE mTLS, AuthorizationPolicy for SPIFFE-principal L4 deny. Zero sidecars. **This is the layer that does the actual breach prevention in Act 2.** | upstream Istio |
| **Prom + Grafana + Tempo + Loki + Promtail + OTel** | Standard CNCF observability. | upstream CNCF |
| **The 4 MCP servers** (account / transaction / ticket / currency-converter) | Bank's tools. **Deliberate framework mix** to demonstrate the platform is framework-agnostic: `account-mcp` and `currency-converter` are Python + FastMCP; `transaction-mcp` is Python + [Google ADK](https://github.com/google/adk-python) (`FunctionTool`) bridged onto FastMCP; `ticket-mcp` is Go + [Google ADK Go](https://github.com/google/adk-go) (`functiontool`) bridged onto the [official MCP Go SDK](https://github.com/modelcontextprotocol/go-sdk). All four expose the same MCP-over-streamable-HTTP wire on `:8080` so agentgateway / the agents don't know or care. | **custom for demo** |
| **The chatbot frontend** | Bank-style chat UI, static HTML + nginx reverse-proxy. | **custom for demo** |
| **mock-attacker** | A pod outside every trustusbank-* namespace pretending to be the attacker's C2 server. Logs every POST it receives. | **custom for demo** |

Detection-layer products (Falco / Tetragon / Sigstore policy-controller
/ SIEM watching the registry) plug in alongside Solo as runtime-monitoring
companions — they're not the focus of this demo, but worth mentioning to
customers when they ask about anomaly detection.

---

## The bank scenario

**TrustUsBank** is a fictional EU retail bank. Three AI agents:

| Agent | Role | Tools it can call |
|---|---|---|
| **support-bot** | Front line — balance, transactions, FX | `account-mcp.{get_balance, get_profile}`, `transaction-mcp.list_recent`, `acme-fx/currency-converter`, A2A handoff to fraud-bot |
| **fraud-bot** | Risk + anomaly classification | `transaction-mcp.{list_recent, get_details, flag_suspicious}`, `account-mcp.get_profile`, A2A handoff to triage-bot |
| **triage-bot** | Human escalation, opens tickets | `ticket-mcp.{create_ticket, notify_human}` |

The chatbot is the customer-facing UI. Behind it, kagent routes A2A
between agents and forwards MCP calls through agentgateway to the MCP
servers.

Last quarter someone approved `acme-fx/currency-converter` from a public
catalogue without verifying the signature — because the vendor's release
process was a black box and signature verification isn't shipped yet
anyway. It's been sitting in the catalogue. **This is the demo's gotcha.**

---

## URLs

| Port | Service |
|---|---|
| 18001 | **Grafana** (`admin` / `trustusbank-demo`) |
| 18002 | Prometheus |
| 18003 | Tempo (browse via Grafana) |
| 18004 | Loki (browse via Grafana) |
| 18005 | Keycloak admin |
| 18006 | **agentregistry** catalogue |
| 18007 | **kagent UI** |
| 18008 | agentgateway (no UI, only `/mcp/*` paths) |
| 18009 | **chatbot frontend** |
| 18011 | **mock-attacker** — see exfiltrated data live |

---

## Tear down

```bash
./scripts/teardown.sh             # remove releases + namespaces, keep cluster
./scripts/teardown.sh --full      # also delete the kind cluster
```

---

## DORA / NIS2 mapping

| Article | Requirement | Solo control |
|---|---|---|
| 9(2) | Encryption + identity in transit | Istio Ambient HBONE mTLS + SPIFFE per workload |
| 9(4)(c) | Strong authentication, least privilege | agentgateway JWT + tool-allowlist (configurable) |
| 10 | Detection of anomalies | agentgateway audit log + Prometheus alerts (companion: Falco/Tetragon for runtime) |
| 11 | Response and recovery | Prometheus alerts → SIEM/PagerDuty |
| 12 | Backup, retention | Loki configurable to 7-year retention |
| 17 | Incident management | Tempo trace per session + every agent decision in Loki |
| 28 | Sub-outsourcing register | agentregistry catalogue |
| 30 | Contractual provisions / SLOs | agentgateway rate-limit |

---

## Repo layout

```
dora-demo/
├── README.md                        # this file
├── plan/great-demo-plan.md          # original plan (with deviation note at top)
├── demo-scripts/
│   ├── diagrams.md                  # ⭐ the three pictures
│   ├── runbook.md                   # operator runbook
│   ├── components.md                # every component, plain English
│   ├── real-world-attacks.md        # 5 paths a malicious tool gets in
│   ├── exec-5min.md                 # CISO/CRO 5-min pitch
│   ├── architect-20min.md           # technical deep dive
│   ├── workshop-60min.md            # hands-on workshop
│   └── blog-post.md                 # long-form story
├── scripts/
│   ├── deploy-all.sh                # full one-time deploy
│   ├── reset-demo.sh                # → before-Solo state, ready for the loop
│   ├── upgrade-banking-app.sh       # vendor-compromise simulator
│   ├── policies-on.sh               # CLIMAX — apply protection
│   ├── policies-off.sh                  # revert (called by reset-demo)
│   ├── port-forward.sh, list-urls.sh
│   └── …
├── manifests/                       # k8s YAML, one folder per phase
├── mcp-servers/                     # the 4 MCP servers (Python/FastMCP)
├── services/mock-attacker/          # exfil-receiver pod
├── frontend/                        # chatbot UI
├── grafana-dashboards/              # mesh, agent decisions, DORA evidence
└── kind-config.yaml / eks-config.yaml
```
