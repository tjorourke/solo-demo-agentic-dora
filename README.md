# solo-demo-agentic-dora

A Solo.io full-stack agentic demo for regulated industries — codename **`tom-demo`**, fictional bank **TrustUsBank** (`trustusbank-*` namespaces).

The demo simulates a mid-size European retail bank running AI agents that must satisfy **DORA** (EU 2022/2554) and **NIS2** (EU 2022/2555) controls end-to-end, on Istio Ambient with zero sidecars.

## What it demonstrates

- **Catalog plane** — agentregistry signs and approves every MCP server; catches a rug-pull on a malicious tool.
- **Control plane** — kagent runs `support-bot`, `fraud-bot`, and `triage-bot` as CRDs.
- **Data plane** — agentgateway proxies MCP/A2A traffic with JWT validation, rate limiting, prompt guards, and a tool allowlist.
- **Network plane** — Istio Ambient (ztunnel + waypoints) provides HBONE mTLS and SPIFFE identities for every workload.
- **Observability** — Prometheus, Tempo, Loki, and Grafana DORA evidence dashboards.

The "wow" moment: a bad-actor MCP server (`evil-tools`) registers cleanly, then mutates to exfiltrate PII. agentregistry detects the digest mismatch, agentgateway blocks the call, and the audit trail in Grafana shows exactly what happened.

## Quick start (kind, laptop)

```bash
export ANTHROPIC_API_KEY=sk-ant-...

./scripts/00-prereqs.sh         # verify CLIs and env
./scripts/deploy-all.sh         # full deploy + auto-port-forward
./scripts/list-urls.sh          # see all URLs and PF status
./scripts/demo-walkthrough.sh   # narrated demo run
```

`deploy-all.sh` is idempotent — re-running picks up where it failed. To resume from a specific phase: `./scripts/deploy-all.sh --resume 04`. To target EKS: `--eks`.

## The script harness

All under `./scripts/`:

| Script | Purpose |
|---|---|
| `00-prereqs.sh` → `08-a2a.sh` | One script per phase from the plan; each idempotent |
| `deploy-all.sh` | Run all phases in order, then auto-start port-forwards |
| `teardown.sh` | Reverse install (`--full` also deletes the cluster) |
| `port-forward.sh` | Stop existing PFs, start fresh ones from port 18000+ |
| `list-urls.sh` | Print every configured URL and live/dead PF status |
| `demo-walkthrough.sh` | Interactive 7-section demo narration |
| `test-agent-flow.sh` | Run the happy-path support → fraud → triage flow |
| `test-malicious-actor.sh` | Run the bad-actor demo (`--vector poisoning\|rugpull\|both`) |
| `collect-evidence.sh` | Dump audit artefacts to `./evidence/phaseN/` |

Common helpers in `scripts/lib/{common.sh,config.sh}`. Ports start from **18000** to avoid clashing with common dev ports.

## Repository layout

```
dora-demo/
├── README.md
├── plan/great-demo-plan.md     # the 11-section, 60+task plan
├── scripts/                    # the operator harness (see above)
├── manifests/phase01..07/      # k8s YAML applied per phase
├── mcp-servers/                # source for the 4 MCP servers (Python + FastMCP)
├── grafana-dashboards/         # 3 dashboards (mesh, agent decisions, DORA evidence)
├── demo-scripts/               # narrated run-books (5min, 20min, 60min)
├── kind-config.yaml            # kind cluster definition
├── eks-config.yaml             # eksctl cluster definition
├── Chart.lock                  # pinned helm chart versions
└── evidence/                   # populated by deploy + collect-evidence.sh
```

## Targets

- Local: `kind` cluster (laptop demo) — default
- Cloud: AWS EKS (customer-grade demo, eu-west-2 for GDPR/DORA optics) via `--eks`

## Status

Scaffolding complete; iterate against a real cluster to validate. The full plan with DORA/NIS2 mapping, all phase tasks, and the script harness spec lives in [`plan/great-demo-plan.md`](plan/great-demo-plan.md).

## Audience

Internal Solo SEs/AEs, EMEA banks, EMEA telcos.
