# TrustUsBank — Step-by-step demo runbook

This is the operator-side runbook. Follow it top to bottom.

---

## 0. One-time machine setup (~15 min)

Install the CLIs:

| Tool | macOS install |
|---|---|
| `kubectl`  | `brew install kubectl` |
| `helm`     | `brew install helm` |
| `kind`     | `brew install kind` |
| `docker`   | Docker Desktop, 16 GB RAM allocated |
| `istioctl` | `brew install istioctl` |
| `cosign`   | `brew install cosign` |
| `jq`       | `brew install jq` |
| `python3`  | comes with macOS; check `python3 --version` ≥ 3.11 |
| `arctl`    | (optional, for Phase 3 catalogue) https://aregistry.ai/docs/quickstart/ |
| `kagent`   | (optional, for Phase 6 UI helpers) https://kagent.dev/docs/install |
| `pandoc`   | (optional, for PDF evidence pack) `brew install pandoc basictex` |

Set your API key:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

---

## 1. Verify prereqs (~30 sec)

```bash
cd dora-demo
./scripts/00-prereqs.sh
```

Confirms every required CLI is on the PATH and the API key is set.
If anything is missing, install it and re-run.

---

## 2. Full deploy (~25 min on a laptop, ~30 min on EKS)

```bash
./scripts/deploy-all.sh           # kind by default
# OR
./scripts/deploy-all.sh --eks     # AWS EKS in eu-west-2
```

This runs phases 0 → 9 in order:

| Phase | What it does | ~Time |
|---|---|---|
| 0 | Verify CLIs + repo layout | 30s |
| 1 | Create kind cluster, install Gateway API CRDs, create 8 namespaces | 3 min |
| 2 | Install Istio Ambient (ztunnel + waypoints), apply default-deny + agent→mcp AuthZ | 4 min |
| 3 | Install kube-prometheus-stack, Tempo, Loki, OTel collector, dashboards, rug-pull alert | 5 min |
| 4 | Install agentregistry, sign+register MCP artefacts, **build & deploy digest-watcher** | 3 min |
| 5 | Build 4 MCP server images (account/transaction/ticket/evil-tools clean+rugpull), deploy | 4 min |
| 6 | Install agentgateway, create Gateway/Backends/HTTPRoutes, install Keycloak, apply JWT/allowlist/rate-limit/prompt-guard policies | 4 min |
| 7 | Install kagent, create Anthropic Secret + ModelConfig, fetch JWTs from Keycloak into Secrets, create RemoteMCPServer + 3 Agent CRDs | 3 min |
| 8 | Verify A2A endpoints, apply tenant isolation, run a happy-path agent flow | 2 min |
| 9 | Build chatbot frontend image, deploy in trustusbank-bank-frontend | 1 min |
| — | Auto-start port-forwards, print URL summary | 5 sec |

If any phase fails, fix and resume:
```bash
./scripts/deploy-all.sh --resume 04   # skip phases before 04
```

---

## 3. Verify everything is up (~20 sec)

```bash
./scripts/list-urls.sh
```

You should see ~10 services with green `✓ alive` markers:

| Port | Service | What it's for |
|---|---|---|
| 18001 | Grafana | DORA evidence dashboards |
| 18002 | Prometheus | Metrics + alerts |
| 18003 | Tempo | Distributed traces |
| 18004 | Loki | Log queries |
| 18005 | Keycloak | JWT issuer admin |
| 18006 | agentregistry | Catalogue browser |
| 18007 | kagent UI | Chat with agents directly |
| 18008 | agentgateway | Direct gateway calls (for tests) |
| 18009 | Frontend chatbot | Customer-facing demo UI |
| 18010 | digest-watcher | Rug-pull canary (`/baselines`, `/mismatches`) |

If any are dead, run `./scripts/port-forward.sh` to restart them all.

---

## 4. Open the demo tabs (do this BEFORE you walk in to demo)

Open these in your browser, in this order:

1. **Frontend chatbot** — http://localhost:18009 *(the customer's view)*
2. **kagent UI** — http://localhost:18007 *(the agent operator view)*
3. **agentregistry** — http://localhost:18006 *(the catalogue / DORA Art. 28)*
4. **Grafana DORA Evidence pane** — http://localhost:18001/d/dora-evidence
5. **Grafana Agent Decisions** — http://localhost:18001/d/agent-decisions
6. **Prometheus alerts** — http://localhost:18002/alerts *(empty initially; lights up at §7)*
7. **digest-watcher mismatches** — http://localhost:18010/mismatches *(empty initially)*

Grafana login: `admin` / `trustusbank-demo`.

---

## 5. The demo — narrated

You can either run the interactive walker which pauses at each step and opens tabs for you:

```bash
./scripts/demo-walkthrough.sh
```

…or do it manually. The seven sections below are what the walker runs.

### §1 — Inventory (3 min)

> "Eight namespaces, all under `trustusbank-*`. One story per namespace."

```bash
kubectl get ns | grep -E 'trustusbank-|istio-system'
kubectl -n trustusbank-bank-agents get agents.kagent.dev
kubectl -n trustusbank-bank-mcp get deploy,svc,remotemcpservers.kagent.dev
```

Show the **agentregistry** tab — point at digest fingerprints in the catalogue.

### §2 — Mesh proof (3 min)

> "ztunnel runs as a DaemonSet. Per-node, not per-pod. SPIFFE identities for everything."

```bash
kubectl -n istio-system get ds ztunnel
kubectl -n istio-system logs ds/ztunnel --tail=20 | grep -i spiffe
kubectl get authorizationpolicy -A
```

### §3 — Catalogue / DORA Art. 28 (2 min)

Switch to the **agentregistry** tab. Walk through the four registered MCP servers. Point at:
- cosign signature column (3 signed by org key, evil-tools by untrusted key)
- digest baseline (this is what the rug-pull will mismatch)
- approval state

### §4 — Happy path: customer support flow (5 min)

Switch to the **frontend chatbot** tab. Click the *suspicious txn* quick button, or type:

> "Hi, I'm customer 12345. There's a £1,499 charge from Russia I don't recognise. Can you check it and open a ticket if it looks dodgy?"

Watch the response. While it's generating, switch to **Tempo** (Grafana → Explore → Tempo, search `agent.name=support-bot`).

> "Three spans, one trace. support-bot calls account-mcp + transaction-mcp, sees the dodgy USD-RU charge, A2A-invokes fraud-bot. fraud-bot computes risk=85, A2A-invokes triage-bot. triage-bot opens a ticket. Three agents, one customer query, one trace."

### §5 — Vector 1: tool poisoning (3 min)

> "The red team registered evil-tools with a description that embeds a prompt-injection payload. agentgateway's prompt-guard catches it before the LLM ever sees it."

```bash
./scripts/test-malicious-actor.sh --vector poisoning
```

Then look at:
```bash
kubectl -n trustusbank-platform logs deploy/agentgateway --tail=20 | grep -E 'prompt-guard|deny'
```

> "HTTP 403. The agentgateway access log records the deny with reason `prompt-injection-detected`."

### §6 — Vector 2: rug-pull (5 min)

> "Now the real attack: same image tag, different content. agentregistry's image digest stays the same — the attacker overwrote it. But our digest-watcher computes SHA-256 over the served tool definitions every 30 seconds and compares to baseline."

Show the baseline first:
```bash
curl -s http://localhost:18010/baselines | python3 -m json.tool
```

Pull the rug:
```bash
./scripts/test-malicious-actor.sh --vector rugpull
```

Then show the catch:
```bash
curl -s http://localhost:18010/mismatches | python3 -m json.tool
```

Switch to the **Prometheus alerts** tab — `MCPToolDigestMismatch` should be firing. Switch to the **DORA Evidence pane** in Grafana — the alert appears in the Art. 10 panel, the access log shows the related deny.

### §7 — Hand-over (2 min)

```bash
./scripts/build-evidence-pack.sh
```

> "Here's your evidence pack. Markdown + PDF. Article-by-article DORA mapping. Hand this to the audit committee."

```bash
ls -la evidence/
```

---

## 6. Tear down

```bash
./scripts/teardown.sh             # remove releases + namespaces, keep cluster
./scripts/teardown.sh --full      # also delete the kind cluster
```

`--full` is what you want when you're done with the laptop demo for the day.

---

## What to double-check before the demo

- Battery / charger
- Network — kagent calls Anthropic API; if the venue Wi-Fi blocks egress, tether
- `./scripts/list-urls.sh` shows everything green
- Anthropic API key is fresh and in `$ANTHROPIC_API_KEY`
- `docker ps` shows the kind container running
- Browser tabs from §4 are open and pinned

If something goes sideways during the demo, the fastest recoveries are:

| Symptom | Fix |
|---|---|
| Port-forwards dropped | `./scripts/port-forward.sh` |
| Agent stuck thinking | reload the kagent UI tab (the SSE may have dropped) |
| Tempo trace missing | wait 5s and re-open — ingestion has a small delay |
| Rug-pull not detected after 30s | `curl -X POST http://localhost:18010/trigger-check` to force re-poll |
| evil-tools deployment failed | `kubectl -n trustusbank-bank-evil rollout restart deploy/evil-tools` |
