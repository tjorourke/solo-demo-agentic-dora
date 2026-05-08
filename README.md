# solo-demo-agentic-dora

A Solo.io full-stack agentic demo for regulated industries — codename **`great`**.

The demo simulates a mid-size European retail bank ("Greatbank") running AI agents that must satisfy **DORA** (EU 2022/2554) and **NIS2** (EU 2022/2555) controls end-to-end, on Istio Ambient with zero sidecars.

## What it demonstrates

- **Catalog plane** — agentregistry signs and approves every MCP server; catches a rug-pull on a malicious tool.
- **Control plane** — kagent runs `support-bot`, `fraud-bot`, and `triage-bot` as CRDs.
- **Data plane** — agentgateway proxies MCP/A2A traffic with JWT validation, rate limiting, prompt guards, and a tool allowlist.
- **Network plane** — Istio Ambient (ztunnel + waypoints) provides HBONE mTLS and SPIFFE identities for every workload.
- **Observability** — Prometheus, Tempo, Loki, and Grafana DORA evidence dashboards.

The "wow" moment: a bad-actor MCP server (`evil-tools`) registers cleanly, then mutates to exfiltrate PII. agentregistry detects the digest mismatch, agentgateway blocks the call, and the audit trail in Grafana shows exactly what happened.

## Targets

- Local: `kind` cluster (laptop demo)
- Cloud: AWS EKS (customer-grade demo, eu-west-2 for GDPR/DORA optics)

## Status

Currently planning. The full 10-phase, 60-task implementation plan lives in [`plan/great-demo-plan.md`](plan/great-demo-plan.md).

## Audience

Internal Solo SEs/AEs, EMEA banks, EMEA telcos.
