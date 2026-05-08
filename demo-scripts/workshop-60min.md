# 60-minute hands-on workshop

**Audience:** customer engineers who will deploy the stack themselves.

## Pre-requisites (sent 24h before)

- Docker Desktop or equivalent, 16 GB RAM allocated
- `kubectl`, `helm`, `kind`, `istioctl`, `cosign`, `python3`, `jq`
- An Anthropic API key
- Cloned `solo-demo-agentic-dora` repo

## Agenda

| Time | Section |
|---|---|
| 0:00 – 0:10 | Why DORA, why agents, why now |
| 0:10 – 0:25 | Phase 0 + 1: cluster + Ambient (you run it) |
| 0:25 – 0:35 | Phase 2 + 3: observability + registry |
| 0:35 – 0:45 | Phase 4 + 5: MCP servers + agentgateway |
| 0:45 – 0:55 | Phase 6 + 7 + 8: agents, A2A, the bad-actor demo |
| 0:55 – 1:00 | Q&A |

## Hands-on

```bash
git clone git@github.com:tjorourke/solo-demo-agentic-dora.git
cd solo-demo-agentic-dora/dora-demo

export ANTHROPIC_API_KEY=sk-ant-...
./scripts/00-prereqs.sh
./scripts/deploy-all.sh
```

That should land at "all green" with 9 URLs printed in ~25 minutes (kind, laptop).

```bash
./scripts/demo-walkthrough.sh
```

Walks through the demo interactively.

## Things that go wrong (FAQ)

**Q: `kind create cluster` hangs.**
A: Increase Docker memory to 16 GB.

**Q: `istioctl install` errors on CRD conflict.**
A: Run `istioctl uninstall --purge -y` first.

**Q: agentregistry UI is empty.**
A: Phase 3 didn't sign or register. Re-run `./scripts/04-registry.sh` and check `arctl artifact list`.

**Q: kagent agents are CrashLoopBackOff.**
A: 99% of the time the Anthropic secret didn't get created. `kubectl -n trustusbank-bank-agents get secret kagent-anthropic` — if missing, re-export the API key and re-run `./scripts/07-kagent.sh`.

**Q: prompt-guard isn't blocking.**
A: Check `kubectl get agentgatewaypolicy -A`. If empty, Phase 5.11 didn't apply — check the manifest path.
