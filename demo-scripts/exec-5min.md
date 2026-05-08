# 5-minute exec demo (CISO / CRO audience)

**Goal:** convince a sceptical regulated-industry executive that Solo + Istio Ambient solves their AI-agent governance problem in time for DORA enforcement.

## Pre-demo checklist (do this 30 seconds before)

- `./scripts/list-urls.sh` — confirm Grafana, agentregistry, kagent UI, Keycloak all show ✓
- Have these tabs already open:
  1. http://localhost:18007 — kagent UI
  2. http://localhost:18006 — agentregistry catalogue
  3. http://localhost:18001/d/dora-evidence — DORA Evidence Pane
- Terminal ready with `./scripts/test-malicious-actor.sh` queued

## Script

**[0:00 – 0:30] Frame the problem**

> *"Your bank is going to be running AI agents inside your network within 12 months. DORA is enforced from January 2025. NIS2 is in transposition. Today I'm going to show you a single platform that gives you DORA Article 9, 10, 17, and 28 evidence — for AI workloads — out of the box."*

**[0:30 – 1:30] Show what's deployed**

Switch to terminal:

```bash
kubectl get ns | grep trustusbank-
kubectl -n trustusbank-bank-agents get agents.kagent.dev
```

> *"Three AI agents. Customer support, fraud, triage. They talk to four MCP tool servers — account, transactions, ticketing, and a fourth, evil-tools, registered by our internal red team."*

**[1:30 – 3:00] Show the catalogue (DORA Art. 28)**

Switch to **agentregistry tab**.

> *"This is your DORA Article 28 sub-outsourcing register. Every AI artefact your bank uses, with provenance, signing status, and digest fingerprints. When the regulator asks 'what's running?' — this is the answer, in one URL."*

Point at digest column.

**[3:00 – 4:30] The rug-pull**

Back to terminal:

```bash
./scripts/test-malicious-actor.sh
```

Watch the output. Then switch to **DORA Evidence Pane**.

> *"The red team pushed a malicious image at the same tag the registry approved an hour ago. agentregistry caught the digest mismatch. agentgateway caught the prompt-injection attempt before the LLM ever saw it. Both attacks landed harmlessly. Every event is in your audit trail, mapped to the DORA article it satisfies."*

**[4:30 – 5:00] Close**

> *"Everything I just showed you is open source, runs on standard Kubernetes, and is deployed by one bash script. We can have this in your sandbox cluster next week. What's the conversation we need to have to make that happen?"*

Hand over the evidence pack PDF (`./evidence/trustusbank-evidence-pack.pdf`).
