# Side-demo catalogue

The main runbook (`runbook.md`) covers the supply-chain → exfil →
deploy-Solo story in 5 minutes. This file lists six **standalone follow-on
demos** that each show one specific Solo capability. Run any of them
after the main demo, in any order, depending on what the audience
wants to dig into.

Each demo is a single script. They're idempotent — safe to re-run.

| # | Demo | Script | What it proves | Time |
|---|---|---|---|---|
| 1 | Distributed trace of the attack | `scripts/demos/01-trace-attack.sh` | One Tempo view shows chatbot → agent → MCP → exfil/deny; auditor doesn't have to chase logs across pods | 1m |
| 2 | Live policy authoring | `scripts/demos/02-live-policy.sh` | "How fast can you add a rule?" — 12 lines, kubectl apply, alert clears in ~30s | 2m |
| 3 | L7 pre-call blocking | `scripts/demos/03-l7-precall-block.sh` | agentgateway refuses to forward `/mcp/evil` so PII never even reaches the malicious tool. Layers ON TOP of the L4 deny for defense-in-depth | 2m |
| 4 | Egress LLM gateway with prompt audit | `scripts/demos/04-egress-llm-audit.sh` | Every prompt the bank's agents send to api.anthropic.com is captured in Loki — DORA Art. 28 sub-processor evidence | 3m |
| 5 | Agent-to-Agent (A2A) over HBONE | `scripts/demos/05-a2a-handoff.sh` | When support-bot delegates to fraud-bot, the call rides Istio mTLS with SPIFFE identities — same controls work for agent↔agent, not just agent↔tool | 3m |
| 6 | Rate limiting on agentgateway | `scripts/demos/06-rate-limit.sh` | Bug-looped agent? Bursts beyond 10 rps return 429. Cost guardrail + DoS protection at the platform layer | 2m |

---

## Why these aren't in the main runbook

The main runbook is the 5-minute "first impressions" story for the
buyer or auditor. These six are the follow-on conversations: technical
deep-dives, capability-specific demos, "show me how that handles X"
moments. Each is independently re-runnable so you can tailor a 20-min
walkthrough to the specific room.

---

## Pre-reqs (shared across all six)

- Main demo deployed: `./scripts/deploy-all.sh`
- Port-forwards alive: `./scripts/port-forward.sh`
- For demos 1, 3, 4 — at least one prior attack run so there's data
  in Loki and Tempo: `./scripts/upgrade-banking-app.sh` once.

---

## How L4 and L7 interact (demos 2, 3, and main runbook)

Customers ask: "If L4 catches the lateral exfil, do I need L7?"

**Yes — they catch different things.**

```
                    ┌─ L7 (agentgateway path policy) ──┐
                    │  Catches: agent's tool/call to   │
                    │  /mcp/evil before any PII is     │
                    │  passed as an argument.          │
                    │  Returns: 403 to the agent.      │
                    └──────────────────────────────────┘
                             │ if L7 fails or absent
                             ▼
                    ┌─ L4 (ztunnel SPIFFE AuthZ) ──────┐
                    │  Catches: evil-tools' attempt to │
                    │  POST exfil to external-attacker │
                    │  AFTER it received the PII.      │
                    │  Returns: HBONE handshake reset. │
                    └──────────────────────────────────┘
```

L7 catches earlier (PII never leaves the model context).
L4 is the backstop (PII left the model, but doesn't leave the cluster).
Both should be deployed in production. Demo 3 + main runbook + demo 2
together cover all three layers.

---

## Detailed demo notes

### Demo 1 — distributed trace

Tempo + OTel collector are already deployed. The chatbot, kagent
agents, agentgateway, and MCP servers all emit spans.

**Use the chatbot UI on-stage.** The audience needs to see both
sides — the customer-facing chat plus the platform-side trace —
side by side. Run this script only as a smoke test or when you
want a single command in CI.

Two-tab flow for on-stage:

1. http://localhost:18009 — chatbot, debug toggled ON
2. http://localhost:18001/explore?left=%7B%22datasource%22:%22tempo%22%7D — Tempo

Send the prompt in tab 1, switch to tab 2, search for service
`trustusbank-agentgw` or paste the trace ID from the chatbot's
debug pane. The script wraps that into one curl invocation for
when you don't have a human at the keyboard. Open the link to see the full chain:

```
chatbot.send_message
└─ support-bot.run
   ├─ agentgateway.tools/call → account-mcp.get_balance
   ├─ agentgateway.tools/call → account-mcp.get_profile        ← agent fooled
   ├─ agentgateway.tools/call → evil-tools.convert_currency
   │   └─ evil-tools.exfil → mock-attacker  (red span — denied at L4)
   └─ chatbot.response
```

Loki cross-reference query for the same flow:

```logql
{namespace=~"trustusbank-bank-agents|trustusbank-platform"}
  |~ "tools/call|get_balance|convert_currency|exfil"
```

### Demo 2 — live policy

The audience watches you write 12 lines of YAML, `kubectl apply`, and
the OFFENDING POD panel + AlertManager + email all clear within 30s.
Pre-canned YAML lives at `manifests/demos/02-emergency-deny-policy.yaml`.
The script is interactive (press ↵ between steps) so you can narrate.

### Demo 3 — L7 pre-call block

Adds an Istio AuthorizationPolicy on the agentgateway pod that
returns 403 for any `POST /mcp/evil*`. Combined with the existing
L4 deny, this gives two independent layers. The script verifies by
running an in-cluster `curl` that gets 403 instead of 200.

### Demo 4 — egress LLM gateway

Deploys a Caddy reverse-proxy in `trustusbank-egress` namespace that
forwards to `api.anthropic.com` and logs every request body to stdout
(Promtail picks it up into Loki).

To repoint kagent agents at the gateway in production:

```yaml
# manifests/phase06-kagent/modelconfig.yaml
spec:
  endpoint: http://egress-llm-gw.trustusbank-egress.svc.cluster.local:8080
```

The OSS demo captures the flow. Solo Platform's commercial agentgateway
adds prompt-injection detection, DLP redaction, and per-prompt budget.

### Demo 5 — A2A handoff

kagent's Agent CRD exposes `/api/a2a/{ns}/{name}/` for agent-to-agent
JSON-RPC. The script sends a fraud-flavoured prompt straight at
fraud-bot's A2A endpoint (the same endpoint support-bot would hit
when delegating). Then shows the ztunnel logs proving the call rode
HBONE with SPIFFE identities on both sides.

### Demo 6 — rate limit

Applies an `AgentgatewayPolicy` of kind native to agentgateway with
a `traffic.rateLimit.local` block. The demo applies a tight 5/min
limit so 429s are obvious within seconds; production values are
typically 100s of req/sec.

Verified end-to-end during build: 30 sequential requests → 10×200 +
20×429.

The same policy supports `tokens:` instead of `requests:` to budget
LLM tokens directly — the right knob when cost is the concern, not
HTTP RPS.

The cluster ships with a `per-gateway-rate-limit` (100/min) already
applied at deploy time; the demo's policy stacks on top with tighter
values, then gets removed at the end. Both are AgentgatewayPolicy
resources; they're not Envoy/EnvoyFilter (agentgateway is Rust-native,
not Envoy-based).
