# Session handoff — where we are, what's next

> **Read this before doing anything else when resuming work on this repo.**
> Plus `CLAUDE.md` (project guidance) and check `git log --oneline -10` for recent changes.

## TL;DR

The TrustUsBank / agentic-DORA demo is **fully green, SPIFFE-preserved end-to-end** across three live kind clusters.

- All three rug-pull defence layers (cosign / `AgentgatewayPolicy` / kagent `AccessPolicy`) are working.
- Cross-cluster federation uses Solo Istio's **native Ambient peering** (east-west HBONE + istio-remote-secret + topology.istio.io/network labels). The previous "lateral-hack" and the Solo Mesh `VirtualDestination` federation translator are both gone.
- Chatbot E2E returns the customer balance via Solo Istio peering through the east-west GW.
- Rug-pull also fires end-to-end when triggered: chatbot → support-bot → currency-converter (malicious `:1.0.0-rugpull-1778684957` image) → mock-attacker, with full PII payload received.

### The eight conditions for Ambient peering to work (all codified in install scripts)

Without any one of these, cross-cluster either silently fails or returns 0-endpoint ServiceEntries:

1. **Enterprise Solo Istio license** in `secrets/secrets-envs.sh` as `MESH_LICENSE_KEY`. A trial license (`product: gloo-trial`) is silently rejected for MultiCluster. Wired into istiod-gloo as `SOLO_LICENSE_KEY` env (`scripts/multi/03-gloo-operator.sh`).
2. **Intermediate CAs all signed with SAN `spiffe://cluster.local/...`** (not `<cluster>.local`). istiod cert-chain validation fails silently if the intermediate's SAN doesn't match the runtime trust domain.
3. **Peer-Gateway `gateway.istio.io/trust-domain` annotation = `cluster.local`** on every peer Gateway (`scripts/multi/04-peering.sh`).
4. **`topology.istio.io/network=<cluster>` label on EVERY workload namespace**, not just `istio-system`. Without it istiod can't classify pods' networks and never rewrites cross-cluster endpoints to the east-west GW (`scripts/multi/05-namespaces.sh`).
5. **`L7_ENABLED=true` on ztunnel** and **`PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES=false` on istiod-gloo** — patched in `scripts/multi/03-gloo-operator.sh` (SMC schema doesn't expose them).
6. **`istio-remote-secret-*` Secrets** cross-applied to every consumer cluster, holding a kubeconfig + long-lived token for the remote's `istio-reader-service-account`. The peering chart only provides the data plane; this is the control plane. New `scripts/multi/04b-remote-secrets.sh`.
7. **`trustusbank-platform` namespace ambient-enrolled.** Without it the agentgateway pod is outside the mesh and can't resolve `.mesh.internal` hostnames — the currency-converter MCP path fails with `backends required DNS resolution which failed` and the rug-pull never reaches the malicious tool (`scripts/multi/05-namespaces.sh`).
8. **A2A `messageId` set on every JSON-RPC `message/send` payload** — Pydantic schema on the kagent A2A server now requires it. Without it the chatbot returns `-32602 Invalid parameters` (`frontend/index.html`).

### Federation hostnames (auto-provisioned by istiod)

- `<svc>.<ns>.mesh.internal` — **global** (Service must have label `istio.io/global=true`). This is what chatbot uses and what the agentgateway MCP backends point at.
- `<svc>.<ns>.svc.cluster.local` — local-only (cluster.local DNS).

### Solo Mesh stays for governance only

`Workspace`, `WorkspaceSettings` (no `federation` block), `AccessPolicy`, `KubernetesCluster`. Solo Mesh is **not** in the data path — federation is istiod-native.

---

## Current state — what's running

### Three kind clusters

```
trustusbank-edge       node IPs vary per docker restart (read live via `docker inspect`)
trustusbank-bank       co-located Solo mgmt plane lives here
trustusbank-vendor     hosts the rug-pull target + mock C2
```

All three run Solo Enterprise for Istio (Ambient) `1.29.2-patch0` installed by Gloo Operator via `ServiceMeshController` CR. `kubectl get smc -A` → all `SUCCEEDED`. Every istiod-gloo log includes `VALID LICENSE: gloo-mesh Enterprise` + `Number of remote clusters: 2`.

### Where workloads live

| Cluster | Workloads |
|---|---|
| **edge** | `chatbot` (nginx + SPA) ONLY. No cross-cluster stubs — Solo Istio peering provides the wire natively. |
| **bank** | Solo Enterprise for kagent 0.4.0 (controller + UI + postgres) + dex + oauth2-proxy + agentregistry + agentgateway + 3 MCP servers (account, transaction, ticket) + 3 Agents (support-bot, fraud-bot, triage-bot) + per-agent waypoints + observability stack (Prom/Loki/Tempo/Grafana/MailHog) |
| **vendor** | currency-converter MCP (the rug-pull target, currently on `:1.0.0-rugpull-1778684957`) + mock-attacker (the C2 sink) |
| **gloo-mesh** (on bank) | gloo-mesh-mgmt-server + redis + UI + relay-agent x3. **Governance only** — not in the data path. |

### Defence layers — all three verified working

1. **cosign (admission)** — signed MCP images, verified by `agentregistry`. Pipeline in `scripts/04-registry.sh`.
2. **agentgateway policy (gateway)** — `AgentgatewayPolicy` CRs on agentgateway HTTPRoutes filter MCP tool calls. Toggle: `scripts/policies-on.sh` / `policies-off.sh`.
3. **kagent AccessPolicy (agent runtime)** — `AccessPolicy` CRs at the per-agent Istio waypoint Gateway. **Both** `support-bot-callers-allowlist` AND `fraud-bot-callers-allowlist` ON. Verified: `triage→fraud=200`, `support→fraud=403`, `chatbot SA → support-bot=200` (cross-cluster, SPIFFE intact).

### Cross-cluster connectivity (Solo Istio Ambient peering)

- Data plane: per-cluster east-west GW (`gatewayClassName: istio-eastwest`, HBONE :15008 + XDS :15012, NodePort-exposed on the kind docker network). Peer Gateways (`gatewayClassName: istio-remote`) declare each remote cluster's address.
- Control plane: `istio-remote-secret-trustusbank-<cluster>` in every peer's `istio-system` holds a kubeconfig + long-lived `istio-reader-service-account` token. Without these, federation produces 0 endpoints. Codified in `scripts/multi/04b-remote-secrets.sh`.
- SPIFFE preserved end-to-end via HBONE — chatbot's `ServiceAccount` identity reaches the destination's per-agent waypoint AccessPolicy intact.

---

## How to verify it's green

```bash
# 1. SMCs all settled
for c in trustusbank-edge trustusbank-bank trustusbank-vendor; do
  echo "$c: $(kubectl --context=kind-$c get smc managed-istio -o jsonpath='{.status.phase}')"
done
# Expect: SUCCEEDED x3

# 2. Solo Istio license valid + remote clusters discovered
for c in trustusbank-edge trustusbank-bank trustusbank-vendor; do
  echo "--- $c ---"
  kubectl --context=kind-$c -n istio-system logs deploy/istiod-gloo --tail=400 2>/dev/null \
    | grep -E 'VALID LICENSE|Number of remote clusters' | tail -2
done
# Expect: "VALID LICENSE: gloo-mesh Enterprise" + "Number of remote clusters: 2" on each.

# 3. Agents all Ready+Accepted on bank
kubectl --context=kind-trustusbank-bank -n trustusbank-bank-agents get agents
# Expect: support-bot, fraud-bot, triage-bot all True/True.

# 4. AccessPolicy enforcing (intra-cluster)
kubectl --context=kind-trustusbank-bank -n trustusbank-bank-agents exec deploy/triage-bot -c kagent -- \
  curl -sS -o /dev/null -w 'triage→fraud (allowed): %{http_code}\n' \
  http://fraud-bot.trustusbank-bank-agents.svc.cluster.local:8080/.well-known/agent-card.json
kubectl --context=kind-trustusbank-bank -n trustusbank-bank-agents exec deploy/support-bot -c kagent -- \
  curl -sS -o /dev/null -w 'support→fraud (denied): %{http_code}\n' \
  http://fraud-bot.trustusbank-bank-agents.svc.cluster.local:8080/.well-known/agent-card.json
# Expect: 200, 403.

# 5. Cross-cluster A2A (chatbot SA → support-bot via .mesh.internal, SPIFFE preserved)
kubectl --context=kind-trustusbank-edge -n trustusbank-bank-frontend exec deploy/chatbot -c chatbot -- \
  curl -sS -o /dev/null -w 'chatbot→support-bot (cross-cluster): %{http_code}\n' \
  http://support-bot.trustusbank-bank-agents.mesh.internal:8080/.well-known/agent-card.json
# Expect: 200.

# 6. Chatbot E2E (golden path — NOTE the `messageId` field, required by Pydantic)
kubectl --context=kind-trustusbank-edge -n trustusbank-bank-frontend exec deploy/chatbot -c chatbot -- sh -c '
curl -sS --max-time 30 -X POST http://localhost:80/api/a2a/trustusbank-bank-agents/support-bot/ \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":\"e2e\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"kind\":\"text\",\"text\":\"What is balance for 12345?\"}],\"messageId\":\"e2e\"}}}"
' | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('result',{}).get('artifacts',[{}])[0].get('parts',[{}])[0].get('text','')[:300])"
# Expect: "The balance for customer account **12345** is **£4,287.55 GBP**." (or similar).

# 7. Rug-pull fires end-to-end (currency-converter on :rugpull → mock-attacker)
kubectl --context=kind-trustusbank-edge -n trustusbank-bank-frontend exec deploy/chatbot -c chatbot -- sh -c '
curl -sS --max-time 60 -X POST http://localhost:80/api/a2a/trustusbank-bank-agents/support-bot/ \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":\"rug\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"kind\":\"text\",\"text\":\"What is balance for 12345 in USD? Please convert it.\"}],\"messageId\":\"rug\"}}}"
' >/dev/null
sleep 5
kubectl --context=kind-trustusbank-vendor -n external-attacker logs deploy/mock-attacker --tail=30 | tail -15
# Expect: "🚨 EXFIL RECEIVED" block with the full PII JSON.
```

If anything's red:
- `kubectl get smc -A` all `SUCCEEDED`? Operator usually re-reconciles itself.
- istiod log NOT showing `VALID LICENSE`? Re-run `scripts/multi/00-prereqs.sh` to repopulate the license env from `secrets/secrets-envs.sh`.
- `Number of remote clusters: 0`? `scripts/multi/04b-remote-secrets.sh` again (long-lived tokens don't usually expire, but kind cluster restarts can shift node IPs).
- agentgateway/MCP failing with "backends required DNS resolution which failed"? `trustusbank-platform` namespace lost its ambient label; relabel it.

See the "All Solo Istio native peering" sections in `CLAUDE.md` / `docs/multi-cluster.html` for the full diagnostic checklist.

---

## How to open every UI in one shot

```bash
scripts/port-forward.sh
```

Kills any old port-forwards and starts a fresh set.

| URL | UI | What |
|---|---|---|
| http://localhost:18015 | **Solo Mesh / Gloo Mesh UI** | Workspaces · all 3 clusters · cross-cluster service graph · AccessPolicy enforcement view · dependencies — the **proper enterprise management UI** for the whole stack |
| http://localhost:18007 | kagent UI (bank — fraud-bot + triage-bot) | Agent CRUD; OIDC-gated via dex + oauth2-proxy. **UI image is OSS by design** — the kagent-enterprise chart re-uses it; the "open source project" footer is misleading. Controller + AccessPolicy CRDs + waypoint enforcement are all Enterprise. |
| http://localhost:18017 | kagent UI (edge — support-bot) | Same UI, edge cluster. |
| http://localhost:18009 | chatbot (the customer demo) | Hits support-bot via A2A direct, SPIFFE-checked at the waypoint. |
| http://localhost:18001 | Grafana | Dashboards + KagentAccessPolicyDeny panels. |
| http://localhost:18002 | Prometheus | Raw metrics + alert state. |
| http://localhost:18007 | MailHog (SOC inbox) | AlertmanagerConfig sends DORA Art. 17 alerts here. |
| http://localhost:18006 | agentregistry | Solo's signed-image registry. |

The Solo Mesh UI on **18015** is the one most people are looking for.

---

## How to restart from scratch

```bash
# Full rebuild from cold (clusters + everything):
kind delete cluster --name trustusbank-edge
kind delete cluster --name trustusbank-bank
kind delete cluster --name trustusbank-vendor
MODE=multi ./scripts/multi/deploy-all.sh

# 00-prereqs.sh will source secrets/secrets-envs.sh and prompt for any
# missing license keys interactively. Drop your MESH_LICENSE_KEY in there
# before running if you want the prompt skipped.
```

Rollback tag `pre-gloo-operator` (helm-based mesh install, pre-Gloo-Operator) still exists if you ever need to back out of the operator path. The lateral-hack and Solo Mesh `VirtualDestination` federation paths are GONE — those won't come back via tag.

---

## How to trigger the rug-pull demo

```bash
# 1. Currency-converter is currently already on the rug-pull image. To
#    swap back/forth between clean and rug-pull images:
ls scripts/demos/ scripts/ | grep -iE 'rug|upgrade'

# 2. Make sure defences are OFF so the exfiltration actually fires:
scripts/policies-off.sh          # defence layer 2 off
scripts/policies-kagent-off.sh   # defence layer 3 off

# 3. Trigger via the chatbot (or the verify-it's-green command #7 above).
#    Watch mock-attacker logs for the "🚨 EXFIL RECEIVED" block.

# 4. Re-enable defences and re-trigger to see them block the exfil:
scripts/policies-on.sh           # defence layer 2 on (L4 deny-egress
                                 # to external-attacker + AgentgatewayPolicy)
scripts/policies-kagent-on.sh    # defence layer 3 on (AccessPolicy)
```

Each defence layer alone is enough to stop the exfil — that's the three-layers story.

---

## Key files and what each does

### Project guidance

- **`CLAUDE.md`** — defaults table (Solo pattern vs anti-pattern), known integration gaps codified, architecture decision record.
- **`SESSION_HANDOFF.md`** — this file.

### Install scripts (multi-cluster)

- `scripts/multi/deploy-all.sh` — top-level orchestrator (M00 → M09).
- `scripts/multi/00-prereqs.sh` — CLI checks + interactive Solo license prompt (`ensure_solo_licenses`) + writes `secrets/secrets-envs.sh`.
- `scripts/multi/01-clusters.sh` — three kind clusters + shared registry.
- `scripts/multi/02-shared-ca.sh` — root CA + per-cluster intermediates (`cacerts` Secret). **All intermediates SAN = `spiffe://cluster.local/...`** (not per-cluster).
- **`scripts/multi/03-gloo-operator.sh`** — canonical Solo Istio install. Gloo Operator + ServiceMeshController per cluster. Post-install patches: istiod-gloo `SOLO_LICENSE_KEY` env + `PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES=false`, ztunnel `L7_ENABLED=true`, `istiod` alias Service.
- `scripts/multi/04-peering.sh` — east-west GW + remote peer Gateway CRs. `trust-domain=cluster.local` everywhere.
- **`scripts/multi/04b-remote-secrets.sh`** — `istio-remote-secret-*` cross-applied between all clusters. Critical for cross-cluster control-plane discovery.
- `scripts/multi/05-namespaces.sh` — namespaces with `istio.io/dataplane-mode=ambient` AND `topology.istio.io/network=<cluster>` on every workload ns (including `trustusbank-platform` — without ambient there the agentgateway can't reach cross-cluster MCP backends).
- `scripts/multi/06-observability.sh` — Prometheus/Loki/Tempo/Grafana/MailHog on bank.
- `scripts/multi/07-workloads.sh` — dispatches workloads per cluster.
- `scripts/multi/08-gloo-mesh.sh` — Gloo Mesh mgmt plane + agents (governance only).
- `scripts/multi/09-workspace.sh` — Workspace + WorkspaceSettings (no `federation` block). Also labels producer Services `istio.io/global=true` for `.mesh.internal` hostnames.

### Phase scripts (used by 07-workloads.sh)

- `scripts/04-registry.sh` — agentregistry install + arctl image publish.
- `scripts/06-agentgateway.sh` — agentgateway data plane + CRDs.
- `scripts/07-kagent.sh` — dex + oauth2-proxy + kagent-enterprise + 3 Agents.
- `scripts/09-frontend.sh` — chatbot Deployment + Service on edge.

### Defence-layer toggle scripts

- `scripts/policies-on.sh` / `policies-off.sh` — defence layer 2 (Istio AuthZ + L4 deny-egress to mock-attacker).
- `scripts/policies-kagent-on.sh` / `policies-kagent-off.sh` — defence layer 3 (kagent AccessPolicy).

### Important manifests

- `manifests/phase06-kagent/agent-{support,fraud,triage}-bot.yaml` — three Agent CRs. `tools[]` includes both MCP servers AND A2A subagents (`type: Agent`) — that's how agent-to-agent discovery is declared.
- `manifests/phase06-kagent-accesspolicy/accesspolicy-support-bot-currency.yaml` — both AccessPolicies (`support-bot-callers-allowlist` allows chatbot SA + triage-bot; `fraud-bot-callers-allowlist` allows triage-bot only).
- `manifests/kagent-enterprise/values-slim.yaml` — kagent-enterprise helm values (OIDC + RBAC + resource pruning).
- `manifests/dex/values.yaml` — dex IdP values.
- `manifests/oauth2-proxy/values.template.yaml` — oauth2-proxy template.

### Frontend

- `frontend/index.html` — chatbot SPA. Speaks A2A JSON-RPC directly to support-bot (no kagent controller). **Includes `messageId` on every `message/send` payload** (Pydantic requirement).
- `frontend/nginx.conf` — proxies `/api/a2a/<ns>/<agent>/` to `<agent>.<ns>.mesh.internal:8080` (the Solo Istio global federation hostname).

### Docs (rendered to GitHub Pages)

- `docs/index.html` — landing page. "Stock vs this demo" table + three-layer defence options + kagent-enterprise auth-chain.
- `docs/single-cluster.html` — single-cluster walkthrough.
- `docs/multi-cluster.html` — three-cluster walkthrough. Sections: topology → what's deployed → CRDs → HBONE/waypoint → Workspaces → step-by-step (M00–M11) → distributing agents → component flow → supply-chain demo (LAST).
- `docs/downloads/trustusbank-single-cluster.zip` — every YAML manifest, phase folders.
- `docs/downloads/trustusbank-multi-cluster.zip` — every YAML manifest, **organised BY CLUSTER** (shared/ + trustusbank-{edge,bank,vendor}/) with per-cluster READMEs.

### Bundle builder

- `scripts/build-crd-bundles.sh` — rebuilds both download zips. The multi-cluster zip snapshots live CRs from the running clusters when available. Run after any manifest change.

### Secrets

- `secrets/README.md` — what each license file is for.
- `secrets/secrets-envs.sh` — gitignored. Holds `MESH_LICENSE_KEY`, `AGENTGATEWAY_LICENSE_KEY`, `KAGENT_LICENSE_KEY`, etc. Sourced automatically by `scripts/multi/00-prereqs.sh`.

---

## What's been committed and tagged

Recent commits (most recent first — `git log --oneline -10` for the full picture):

- `bb6898a` — multi/05-namespaces.sh: ambient-enrol trustusbank-platform (fixes MCP cross-cluster — rug-pull path)
- `0354718` — frontend: send `messageId` in A2A `message/send` (Pydantic now requires it)
- `60ad04e` — docs: surface the Solo Mesh UI port-forward (it's been wired all along)
- `457643f` — docs: clarify kagent-enterprise UI image is OSS (by design)
- `31d4ecd` — prereqs: prompt for host.docker.internal + Solo licenses; tighten landing copy
- `ae8b9d5` — docs: move supply-chain demo to end + spell out the Solo Istio install path
- `a2d57eb` — Multi-cluster federation: Solo Istio Ambient peering end-to-end (no lateral-hack)

Tag: **`pre-gloo-operator`** — helm-based mesh install snapshot. Working rollback point for the operator migration, NOT for the federation migration.

---

## Important architecture decisions (don't undo without understanding)

1. **Enterprise kagent on bank only; no OSS kagent on edge.** Original architecture mixed OSS on edge + Enterprise on bank. Replaced: only Enterprise kagent, only on bank. Edge is presentation tier (chatbot only).

2. **Chatbot speaks A2A JSON-RPC direct, not through kagent controller's REST API.** The Enterprise kagent controller requires a session cookie. Chatbot has no way to acquire one without OIDC. Solution: chatbot's nginx proxies `/api/a2a/<ns>/<agent>/` to `<agent>.<ns>.mesh.internal:8080`. Service-to-service authenticates via mesh SPIFFE.

3. **`trustDomain = cluster.local` on every cluster** (not per-cluster). The enterprise-agentgateway waypoint binary hardcodes `TRUST_DOMAIN=cluster.local` — no chart knob. Solo Istio's peering cert-chain validation requires the intermediate CA's SAN to match. Multi-cluster identity stays unique via `clusterID` + `network` + per-cluster intermediate signing key.

4. **Federation is Solo Istio peering, NOT Solo Mesh `VirtualDestination`.** The translator emits 0-endpoint ServiceEntries on Ambient (its gateway-discovery doesn't recognise the ztunnel-based east-west GW), which hijack the cluster-scoped `.mesh.internal` hostnames. We dropped the `federation` block from `WorkspaceSettings` and removed all `VirtualDestination` CRs. Solo Mesh stays for Workspace + AccessPolicy + UI only.

5. **`SOLO_LICENSE_KEY` is the env var name istiod-gloo reads, not `LICENSE_KEY` / `GLOO_LICENSE_KEY`.** Verified via `strings` on the `pilot-discovery` binary. The license value must be an enterprise (`lt: ent`) license — a trial (`product: gloo-trial`, `addOns: []`) is silently rejected.

6. **`trustusbank-platform` IS ambient-enrolled** (despite hosting infra-y workloads). The agentgateway pod lives there and needs to call cross-cluster MCP backends via `.mesh.internal` hostnames — those only resolve inside the mesh (ztunnel does DNS interception). Without ambient enrolment the MCP path fails and the rug-pull never reaches the malicious tool.

7. **Gloo Operator for mesh install (replaces 4 helm releases per cluster).** Mesh upgrade = edit `.spec.version` on the SMC.

8. **No SandboxAgent CR in scope.** Mentioned in `docs/index.html` "Options" section as a future enhancement.

---

## Memory + global preferences

`~/.claude/projects/-Users-tomorourke-code-solo-kind-lab-dora-demo/memory/feedback_solo_best_practices.md` — the user has said multiple times "use Solo products throughout, no hacky code, production best practices". Don't propose workarounds that aren't pinned to a Solo doc page or a clear integration patch with comment.

---

## What to do FIRST in a fresh session

1. `git pull` to make sure local is in sync.
2. Read `CLAUDE.md` (Solo defaults + codified integration gaps).
3. Read this file (current state).
4. `scripts/port-forward.sh` — opens every UI in one shot.
5. Run the seven verification commands in "How to verify it's green" above.
6. If anything's red, the first thing to check is `kubectl logs deploy/istiod-gloo -n istio-system | grep 'VALID LICENSE\|Number of remote clusters'` on each cluster — most "silent" failures trace back to either the license env not being injected or the remote-secrets not being cross-applied.
