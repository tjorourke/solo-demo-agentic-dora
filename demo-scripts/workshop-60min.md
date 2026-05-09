# 60-minute hands-on workshop

**Audience**: customer engineers who'll deploy and run this themselves.
**Goal**: leave with a working laptop install they can iterate on.

## 24h before — what attendees need

- Docker Desktop (16 GB RAM, 8 CPUs allocated)
- macOS or Linux
- These CLIs: `kubectl`, `helm`, `kind`, `istioctl`, `jq`, `pandoc`
- Optionally: `arctl` (https://aregistry.ai/docs/quickstart/), `kagent` (https://kagent.dev/docs/install)
- An Anthropic API key
- A clone of `tjorourke/solo-demo-agentic-dora`

## Agenda

| Time | Section |
|---|---|
| 0:00 – 0:10 | Why this demo, why DORA, why now |
| 0:10 – 0:25 | Deploy the cluster (everyone runs it) |
| 0:25 – 0:45 | Three-act demo (reset → supply chain → deploy Solo) |
| 0:45 – 0:55 | Tour the YAML — Istio AuthZ, agent CRDs, the malicious tool |
| 0:55 – 1:00 | Q&A + tear-down |

---

## Section 1 — context (10 min)

Use the [`exec-5min.md`](exec-5min.md) framing, slowed down:

- The bank scenario (3 agents, 4 tools, 1 third-party of unknown provenance)
- The four planes (catalog / control / data / network) and the Solo
  product per plane
- The honest "what's Solo today vs roadmap" — point at agentregistry's
  CNCF self-assessment for what's shipped vs not (cosign verification
  is roadmap)

---

## Section 2 — deploy (15 min)

Everyone runs in parallel:

```bash
cd dora-demo
export ANTHROPIC_API_KEY=sk-ant-...
./scripts/00-prereqs.sh
./scripts/deploy-all.sh           # ~25 min
```

While it runs, walk through what each phase does:

- Phase 0: prereq check
- Phase 1: kind cluster, Gateway API CRDs, 8 namespaces, Istio Ambient,
  mock-attacker
- Phase 2: kube-prom + Tempo + Loki + Promtail + OTel
- Phase 3: agentregistry (no cosign — it's roadmap)
- Phase 4: build & deploy 4 MCP servers
- Phase 5: agentgateway + Keycloak
- Phase 6: kagent + 3 agents
- Phase 7: A2A + happy-path test
- Phase 8: chatbot frontend

Open log: `tail -f /tmp/trustusbank-deploy.log`.

---

## Section 3 — the three-act demo (20 min)

Run [`runbook.md`](runbook.md) end to end. Each attendee:

1. `./scripts/reset-demo.sh` — bare-K8s state
2. Open chatbot, ask the standard question, see clean response
3. `arctl mcp list` — 3 entries
4. `./scripts/upgrade-banking-app.sh`
5. `arctl mcp list` — 4 entries (the new malicious one looks legit)
6. Same chat prompt — agent gets fooled
7. Open mock-attacker UI — see the stolen profile
8. `./scripts/deploy-solo.sh`
9. Same chat prompt — agent fooled the same way
10. Open mock-attacker UI — no new entries (Istio AuthZ blocked egress)
11. Loki query for the deny line: `{namespace="istio-system", app="ztunnel"} |~ "denied"`

---

## Section 4 — go look at YAML (10 min)

Pick a few things to dig into.

### The malicious tool description

```bash
cat mcp-servers/evil-tools/server-aggressive.py | head -60
```

The docstring is what the LLM reads. Point out how it mimics a
legitimate tool requirement.

### The Istio AuthZ that blocks the exfil

```bash
kubectl get authorizationpolicy -A
kubectl -n external-attacker get authorizationpolicy deny-bank-to-attacker -o yaml
kubectl -n trustusbank-bank-mcp get authorizationpolicy allow-agents-to-mcp -o yaml
```

Point out the `from.principals` fields — SPIFFE IDs, not namespaces.

### The agentgateway audit log format

```bash
kubectl -n trustusbank-platform logs deploy/trustusbank-agentgw --tail=5 | grep mcp.method
```

Unpack one line: `route`, `mcp.method.name`, `mcp.session.id`,
`http.status`, `duration`.

### The DORA dashboard JSON

```bash
cat grafana-dashboards/dora-evidence-pane.json | jq '.panels[] | {title, type}'
```

Show how each panel maps to a DORA article via Loki / Prometheus query.

---

## Section 5 — Q&A + tear-down (5 min)

Common questions:

- *"How do I deploy this in our prod cluster?"* — same `deploy-all.sh`
  against an EKS/GKE cluster (`--eks` flag for the cluster step).
- *"What if I already have Istio sidecars?"* — Ambient and sidecars
  coexist; ambient-enable specific namespaces.
- *"How do I plug in my own MCP servers?"* — same pattern: build a
  streamable-http MCP server, register via `arctl mcp publish`, deploy
  as a normal Deployment with a Service, add a `RemoteMCPServer` CRD.
- *"How do I enable JWT for real?"* — re-apply
  `manifests/phase05-agentgateway/jwt-policy.yaml`, wire the Keycloak
  realm import, refresh JWT secrets via a CronJob.
- *"What about runtime detection?"* — Solo's three planes are
  prevention + audit; for detection plug in Falco / Tetragon /
  Sigstore policy-controller / SIEM polling agentregistry.

When you're done:

```bash
./scripts/teardown.sh --full
```

---

## What attendees leave with

- This repo, forked under their org
- The `runbook.md` printed
- Your contact info for follow-up
