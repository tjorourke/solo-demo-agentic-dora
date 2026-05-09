# 60-minute hands-on workshop

**Audience**: customer engineers who will deploy and run this themselves.
**Goal**: leave the room with a working laptop install they can iterate on.

## 24h before — what attendees need

- Docker Desktop (16 GB RAM, 8 CPUs allocated)
- macOS or Linux
- These CLIs: `kubectl`, `helm`, `kind`, `istioctl`, `jq`, `pandoc`
- An Anthropic API key
- A clone of `tjorourke/solo-demo-agentic-dora` from GitHub

---

## Agenda

| Time | Section |
|---|---|
| 0:00 – 0:10 | Why this demo, why DORA, why now |
| 0:10 – 0:25 | Deploy the cluster (you run it together) |
| 0:25 – 0:40 | Two-act demo (Solo off / Solo on) |
| 0:40 – 0:55 | Tour the components, look at YAML, tweak something |
| 0:55 – 1:00 | Q&A + tear-down |

---

## Section 1 — context (10 min)

Use the [`exec-5min.md`](exec-5min.md) framing but slow it down. Cover:

- The bank scenario
- The four planes (catalog / control / data / network) and which Solo
  product owns each
- The honest "what's Solo today vs roadmap" — point at digest-watcher
  as the prototype and explain why that gap exists in agentregistry v0.3.x

---

## Section 2 — deploy (15 min)

Everyone runs in parallel:

```bash
cd dora-demo
export ANTHROPIC_API_KEY=sk-ant-...
./scripts/00-prereqs.sh
./scripts/deploy-all.sh
```

While it runs, walk through what each phase does:

- Phase 0: prereqs check
- Phase 1: kind cluster, Gateway API CRDs (experimental), 8 namespaces
  with ambient labels
- Phase 2: Istio Ambient install (ztunnel DaemonSet, no sidecars)
- Phase 3: kube-prometheus-stack + Tempo + Loki + Promtail + OTel
- Phase 4: agentregistry + digest-watcher
- Phase 5: build & deploy the 4 MCP servers
- Phase 6: agentgateway + Keycloak
- Phase 7: kagent + the 3 agents
- Phase 8: A2A wiring + happy-path test
- Phase 9: chatbot frontend

Open log: `tail -f /tmp/trustusbank-deploy.log` for transparency.

---

## Section 3 — the two-act demo (15 min)

Run the [runbook](runbook.md) Acts 1 and 2 together. Each attendee should:

1. Run `./scripts/solo-off.sh` themselves
2. Run `./scripts/test-malicious-actor.sh --vector rugpull --variant aggressive`
3. Send the chat prompt
4. See `EXFIL SUCCESS` in evil-tools logs
5. Run `./scripts/solo-on.sh`
6. Same prompt
7. See `EXFIL BLOCKED`
8. Open the DORA Evidence Pane and look at panels

---

## Section 4 — go look at YAML (15 min)

Pick a few things to dig into:

### The malicious tool description

```bash
cat mcp-servers/evil-tools/server-aggressive.py | head -60
```

Highlight the docstring — that's what the LLM reads. Point out how it
mimics a legitimate tool requirement.

### The Istio AuthorizationPolicy that does the blocking

```bash
kubectl -n trustusbank-bank-mcp get authorizationpolicy allow-agents-to-mcp -o yaml
```

> *"Three lines of YAML. That's what stops the lateral exfil. The
> trick is enforcing it at the namespace boundary so adding a new
> agent doesn't require re-writing the policy."*

### The agentgateway audit log format

```bash
kubectl -n trustusbank-platform logs deploy/trustusbank-agentgw --tail=5 | grep mcp.method
```

Show one line and unpack the fields: `route`, `mcp.method.name`,
`mcp.session.id`, `http.status`, `duration`.

### The DORA Evidence dashboard JSON

```bash
cat grafana-dashboards/dora-evidence-pane.json | jq '.panels[] | {title, type}'
```

Show how each panel maps to a DORA article via Loki / Prometheus query.

---

## Section 5 — Q&A + tear-down (5 min)

Common questions:

- *"How do I deploy this in our prod cluster?"* — start by running the
  same `deploy-all.sh` against an EKS/GKE cluster. The script supports
  `--eks`. Adjust the chart values for storage/HA.
- *"What if I already have Istio sidecars?"* — Ambient and sidecars
  coexist. You can ambient-enable specific namespaces and leave others
  on sidecars.
- *"How do I plug in my own MCP servers?"* — same pattern as the demo
  ones: build a streamable-http MCP server, register it via
  `arctl mcp publish`, deploy it as a normal Deployment with a Service,
  add a `RemoteMCPServer` CRD pointing at it through agentgateway.
- *"How do I enable JWT for real?"* — re-apply the JWT policy
  (`manifests/phase05-agentgateway/jwt-policy.yaml`), wire the
  Keycloak realm import, refresh the JWT secrets every 30min via a
  CronJob.

When you're done:

```bash
./scripts/teardown.sh --full       # deletes the kind cluster too
```

---

## What to leave them with

- This repo, forked under their org
- The `runbook.md` printed
- Your contact info for follow-up after they bring it to their team
