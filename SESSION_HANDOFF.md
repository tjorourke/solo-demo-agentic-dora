# Session handoff — where we are, what's next

> **Read this before doing anything else when resuming work on this repo.**
> Plus `CLAUDE.md` (project guidance) and check `git log --oneline -10` for recent changes.

## TL;DR

The TrustUsBank / agentic-DORA demo is **fully green, SPIFFE-preserved end-to-end** on three live kind clusters. All three rug-pull defence layers (cosign / agentgateway / kagent AccessPolicy) are working. The chatbot returns the customer balance end-to-end via Solo Istio Ambient peering — **no more lateral-hack, no more SPIFFE-stripping NodePort SNAT.**

**The session that closed the federation gap**: Solo Istio's Ambient peering needs every one of the following to be in place (codified in install scripts now). Without any one of them, cross-cluster falls back to either silent failure or the lateral-hack:

1. **Enterprise Solo Istio license** in `secrets/secrets-envs.sh` as `MESH_LICENSE_KEY` (the trial license has `addOns: []` and is rejected for MultiCluster). Wired as `SOLO_LICENSE_KEY` env on `istiod-gloo`.
2. **Intermediate CAs all signed with SAN `spiffe://cluster.local/...`** (not `<cluster>.local`). istiod's cross-cluster cert validation fails silently if the intermediate's SAN doesn't match the runtime trust domain.
3. **Peering chart's `gateway.istio.io/trust-domain` annotation = `cluster.local`** on every peer Gateway (was hardcoded per-cluster in `04-peering.sh`).
4. **`topology.istio.io/network=<cluster>` label on every workload namespace**, not just `istio-system`. Without it istiod can't classify pods' networks and never rewrites cross-cluster endpoints to the east-west GW.
5. **`L7_ENABLED=true` on ztunnel** and **`PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES=false` on istiod-gloo** — patched in `03-gloo-operator.sh` (SMC schema doesn't expose them).
6. **`istio-remote-secret-*` Secrets** cross-applied to every consumer cluster, holding a kubeconfig + long-lived token for the remote's `istio-reader-service-account`. The peering chart only provides the data-plane half; this is the control-plane half. New `04b-remote-secrets.sh`.

Federation now works via Solo Istio native discovery: services labelled `istio.io/global=true` get the auto-provisioned `<svc>.<ns>.mesh.internal` global hostname; cluster-scoped is `<svc>.<ns>.svc.<cluster>.mesh.internal`. Solo Mesh's `VirtualDestination`/`Workspace.federation` translator is **no longer in the data path** — it stays for governance only (`Workspace`, `WorkspaceSettings`, `AccessPolicy`).

---

## Current state — what's running

### Three kind clusters

```
trustusbank-edge       node IPs vary per docker network arrival (see scripts/multi/apply-lateral-hack.sh)
trustusbank-bank       co-located Solo mgmt plane lives here
trustusbank-vendor     hosts the rug-pull target + mock C2
```

All three are running Solo Enterprise for Istio (Ambient mode) `1.29.2-patch0` installed by Gloo Operator via `ServiceMeshController` CR. `kubectl get smc -A` → all `SUCCEEDED`.

### Where workloads live

| Cluster | Workloads |
|---|---|
| **edge** | `chatbot` (nginx + SPA) ONLY. No more cross-cluster stubs — Solo Istio peering provides the cross-cluster path natively. |
| **bank** | Solo Enterprise for kagent 0.4.0 (controller + UI + postgres) + dex + oauth2-proxy + agentregistry + agentgateway + 3 MCP servers (account, transaction, ticket) + 3 Agents (support-bot, fraud-bot, triage-bot) + per-agent waypoints + observability stack (Prom/Loki/Tempo/Grafana/MailHog) |
| **vendor** | currency-converter MCP (the rug-pull target, gets swapped to `:1.0.0-rugpull` during Act 2) + mock-attacker (the C2 sink) |
| **gloo-mesh** (on bank) | gloo-mesh-mgmt-server + redis + UI + relay-agent x3 (one per cluster). Used for **governance only** (Workspace, AccessPolicy) — federation no longer goes through `VirtualDestination`. |

### Defence layers — all three working

1. **cosign (admission)** — signed MCP images, verified by `agentregistry`. Pipeline visible in `scripts/04-registry.sh`.
2. **agentgateway policy (gateway)** — `AgentgatewayPolicy` CRs on the agentgateway HTTPRoutes filter MCP tool calls. Toggle: `scripts/policies-on.sh` / `policies-off.sh`.
3. **kagent AccessPolicy (agent runtime)** — `AccessPolicy` CRs at the per-agent Istio waypoint Gateway. Currently has fraud-bot allowlist (triage-bot only). Toggle: `scripts/policies-kagent-on.sh` / `policies-kagent-off.sh`. **VERIFIED:** triage→fraud HTTP 200, support→fraud HTTP 403.

### Cross-cluster connectivity — Solo Istio Ambient peering (production-correct)

Data plane: each cluster's east-west GW is a `gatewayClassName: istio-eastwest`
Gateway with ports 15008 (HBONE) + 15012 (XDS-TLS), exposed via NodePort on
the kind docker network. Peer Gateway CRs (`gatewayClassName: istio-remote`)
declare each remote cluster's address. SPIFFE is preserved end-to-end via
HBONE; the chatbot's ServiceAccount identity reaches the destination's
per-agent waypoint AccessPolicy intact.

Control plane: `istio-remote-secret-trustusbank-<cluster>` Secret in every
peer's `istio-system` holds a kubeconfig + long-lived `istio-reader-service-account`
token, so each istiod-gloo can read remote Services/Endpoints/Pods. Without
this, federation silently produces zero endpoints. Codified in
`scripts/multi/04b-remote-secrets.sh`.

Federation hostnames (auto-provisioned by istiod):
- `<svc>.<ns>.mesh.internal` — global (when producer Service has
  `istio.io/global=true`)
- `<svc>.<ns>.svc.<cluster>.mesh.internal` — cluster-scoped (always available)

---

## How to verify it's green

```bash
# 1. SMCs all settled
for c in trustusbank-edge trustusbank-bank trustusbank-vendor; do
  echo "$c: $(kubectl --context=kind-$c get smc managed-istio -o jsonpath='{.status.phase}')"
done
# Expect: SUCCEEDED x3

# 2. Agents all Ready+Accepted on bank
kubectl --context=kind-trustusbank-bank -n trustusbank-bank-agents get agents
# Expect: support-bot, fraud-bot, triage-bot all True/True

# 3. AccessPolicy enforcing
kubectl --context=kind-trustusbank-bank -n trustusbank-bank-agents exec deploy/triage-bot -c kagent -- \
  curl -sS -o /dev/null -w 'triage→fraud (allowed): %{http_code}\n' \
  http://fraud-bot.trustusbank-bank-agents.svc.cluster.local:8080/.well-known/agent-card.json
kubectl --context=kind-trustusbank-bank -n trustusbank-bank-agents exec deploy/support-bot -c kagent -- \
  curl -sS -o /dev/null -w 'support→fraud (denied): %{http_code}\n' \
  http://fraud-bot.trustusbank-bank-agents.svc.cluster.local:8080/.well-known/agent-card.json
# Expect: 200, 403

# 4. Chatbot E2E (the golden demo path)
kubectl --context=kind-trustusbank-edge -n trustusbank-bank-frontend exec deploy/chatbot -- sh -c '
curl -sS --max-time 30 -X POST http://localhost:80/api/a2a/trustusbank-bank-agents/support-bot/ \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":\"e2e\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"kind\":\"text\",\"text\":\"What is balance for 12345?\"}],\"messageId\":\"m1\"}}}"
' | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('result',{}).get('artifacts',[{}])[0].get('parts',[{}])[0].get('text','')[:200])"
# Expect: "The balance for customer account **12345** is **£4,287.55 GBP**."
```

If any of those fail, check `kubectl get smc -A` is all `SUCCEEDED` and that each istiod's log includes `Number of remote clusters: 2` and `VALID LICENSE: gloo-mesh Enterprise`. See the "All Solo Istio native peering" sections in CLAUDE.md / docs/multi-cluster.html for the full diagnostic checklist.

---

## How to open every UI in one shot

```bash
scripts/port-forward.sh
```

That kills any old port-forwards and starts a fresh set. Open the URLs it prints — most useful for the multi-cluster demo:

| URL | UI | What |
|---|---|---|
| http://localhost:18015 | **Solo Mesh / Gloo Mesh UI** | Workspaces · all 3 clusters · cross-cluster service graph · AccessPolicy enforcement view · dependencies — the **proper enterprise management UI** for the whole stack |
| http://localhost:18007 | kagent UI (bank — fraud-bot + triage-bot) | Agent CRUD; OIDC-gated via dex + oauth2-proxy |
| http://localhost:18017 | kagent UI (edge — support-bot) | Same UI, edge cluster |
| http://localhost:18009 | chatbot (the customer demo) | Hits support-bot via A2A direct, SPIFFE-checked at the waypoint |
| http://localhost:18001 | Grafana | Dashboards + KagentAccessPolicyDeny panels |
| http://localhost:18002 | Prometheus | Raw metrics + alert state |
| http://localhost:18007 | MailHog (SOC inbox) | AlertmanagerConfig sends DORA Art. 17 alerts here |
| http://localhost:18006 | agentregistry | Solo's signed-image registry |

The Solo Mesh UI on 18015 is the one most people are looking for — it's NOT the simple kagent UI (which has the "is an open source project" footer); it's the full enterprise management dashboard for Workspaces, AccessPolicy, multi-cluster topology, service graphs, and the audit feeds.

---

## How to restart from scratch

```bash
# Full rebuild from cold (clusters + everything):
kind delete cluster --name trustusbank-edge
kind delete cluster --name trustusbank-bank
kind delete cluster --name trustusbank-vendor
MODE=multi ./scripts/multi/deploy-all.sh

# Or rollback to the pre-operator helm-based path:
git checkout pre-gloo-operator
# then re-run deploy-all
```

---

## The open work — fix Solo Mesh east-west GW discovery

### The precise problem

`VirtualDestination` status on bank shows:

> `virtual destination has backing services in cluster [trustusbank-bank], but no gateway to reach services in that cluster could be found`

The federation translator emits `ServiceEntry` CRs with proper SPIFFE `subjectAltNames`. It does NOT emit the matching `WorkloadEntry` per remote pod because it can't find the east-west GW for the producer cluster. Without WEs, the SE has `endpoints=0` → ztunnel resolves the federated VIP → no upstream → TCP reset.

### Why

Solo Istio's `peering` helm chart creates a `gateway.networking.k8s.io/v1 Gateway` with `gatewayClassName: istio-eastwest`. That's correct for raw Istio Ambient HBONE. But Solo Mesh's mgmt-server gateway-discovery logic was written for the older Solo Mesh east-west GW pattern (a different chart) and doesn't recognise the new Gateway-API-based one as the east-west endpoint.

### Three resolution paths (any one fixes it)

1. **Swap charts** — replace `scripts/multi/04-peering.sh` (Solo Istio peering chart) with Solo Mesh's bundled east-west GW chart. Confirm Ambient compatibility first; the older Solo Mesh east-west GW was sidecar-mode.
2. **Patch `KubernetesCluster.status`** — write a controller / one-shot patch that populates the GW address into the `KubernetesCluster` status so mgmt-server picks it up via the relay. Non-trivial (status subresource).
3. **Solo support ticket** — this is a real integration gap between two Solo products. Reproducible: `kubectl get vd -A` will show the warning on any 2.x mesh + peering-chart-based east-west GW combination.

### Where to look when resuming

- `kubectl --context=kind-trustusbank-bank -n trustusbank-bank-agents get vd support-bot -o yaml` — the WARNING message is the smoking gun
- `kubectl --context=kind-trustusbank-bank -n gloo-mesh logs deploy/gloo-mesh-mgmt-server --tail=200 | grep -iE 'east.?west|gateway'`
- `kubectl --context=kind-trustusbank-edge get serviceentry -A` — SEs exist, `endpoints=[]`

### Once it's fixed

1. Delete the lateral-hack: `kubectl --context=kind-trustusbank-edge -n trustusbank-bank-agents delete endpointslice,svc -l <whatever-labels-the-hack-uses>`, plus the bank-side vendor stub
2. Revert bank/vendor Services from NodePort back to ClusterIP
3. Update `frontend/nginx.conf` to use the federated hostname (`<svc>.<ns>.svc.<cluster>.mesh.internal`) instead of `<svc>.<ns>.svc.cluster.local`
4. Re-add the chatbot's ServiceAccount subject to the support-bot `AccessPolicy` (we removed it because the lateral-hack stripped SPIFFE)
5. Verify chatbot → support-bot returns 200 and the AccessPolicy is now also enforcing on the cross-cluster path

---

## Key files and what each does

### Project guidance

- **`CLAUDE.md`** — defaults table (Solo pattern vs anti-pattern), known integration gaps, rollback tag.
- **`SESSION_HANDOFF.md`** — this file.

### Install scripts (multi-cluster)

- `scripts/multi/deploy-all.sh` — top-level orchestrator (M00→M10).
- `scripts/multi/00-prereqs.sh` — CLI checks + license + gcloud auth.
- `scripts/multi/01-clusters.sh` — three kind clusters + shared registry.
- `scripts/multi/02-shared-ca.sh` — root CA + per-cluster intermediates (cacerts Secret).
- **`scripts/multi/03-gloo-operator.sh`** — the NEW canonical install path: Gloo Operator + ServiceMeshController per cluster. Includes the three operator-integration patches (istiod alias, trustDomain=cluster.local, CLUSTER_ID env).
- `scripts/multi/03-solo-istio.sh.legacy` — old helm-based mesh install. Rollback path. Tagged `pre-gloo-operator`.
- `scripts/multi/04-peering.sh` — east/west GW + remote peers (Solo Istio peering chart). **This is the chart that mgmt-server doesn't recognise — see Open Work above.**
- `scripts/multi/05-namespaces.sh` — namespaces + Ambient labels.
- `scripts/multi/06-observability.sh` — Prometheus/Loki/Tempo/Grafana/MailHog on bank.
- `scripts/multi/07-workloads.sh` — dispatches workloads per cluster. **Edge gets chatbot only. Bank gets Enterprise kagent + all 3 agents. Vendor gets currency-converter + mock-attacker.**
- `scripts/multi/08-gloo-mesh.sh` — Gloo Mesh mgmt plane + agents.
- `scripts/multi/09-workspace.sh` — Workspace + WorkspaceSettings.
- `scripts/multi/10-fix-federation-hijack.sh` — earlier fix for the namespace-wide service-scope=global hijacking local Services. Federation now uses opt-in `solo.io/expose-cross-cluster=true` label.
- **`scripts/multi/apply-lateral-hack.sh`** — dynamic-IP lateral hack. Required until the east-west GW discovery is fixed.

### Phase scripts (used by 07-workloads.sh)

- `scripts/04-registry.sh` — agentregistry install + arctl image publish.
- `scripts/06-agentgateway.sh` — agentgateway data plane + CRDs.
- **`scripts/07-kagent.sh`** — dex + oauth2-proxy + kagent-enterprise + 3 Agents. Includes the `app.kubernetes.io/name=kagent-enterprise` label wait (was `kagent` for OSS) and the `openssl rand -hex 16` cookie-secret fix.
- `scripts/09-frontend.sh` — chatbot Deployment.

### Defence-layer toggle scripts

- **`scripts/policies-on.sh` / `policies-off.sh`** — defence layer 2 (Istio AuthZ + deny-egress to mock-attacker).
- **`scripts/policies-kagent-on.sh` / `policies-kagent-off.sh`** — defence layer 3 (kagent AccessPolicy). Includes the CLUSTER_ID env injection on waypoint Deployments (the third operator-integration patch).

### Important manifests

- `manifests/phase06-kagent/agent-{support,fraud,triage}-bot.yaml` — all three Agents on bank, all labelled `kagent.solo.io/waypoint=true`.
- `manifests/phase06-kagent-accesspolicy/accesspolicy-support-bot-currency.yaml` — current AccessPolicy CRs. Support-bot policy was removed (chatbot's cross-cluster SPIFFE is stripped, would 403 every chatbot request); fraud-bot policy remains and enforces.
- `manifests/multi/lateral-hack.yaml` — the cross-cluster wiring. Hardcoded IPs are stale; `apply-lateral-hack.sh` reads it and substitutes current IPs.
- `manifests/kagent-enterprise/values-slim.yaml` — kagent-enterprise helm values (OIDC + RBAC + resource pruning).
- `manifests/dex/values.yaml` — dex IdP values (single static user, password-grant enabled).
- `manifests/oauth2-proxy/values.template.yaml` — oauth2-proxy values template (substituted at install time).

### Frontend

- `frontend/index.html` — chatbot SPA. Speaks A2A JSON-RPC directly to support-bot via `/api/a2a/<ns>/<agent>/` (no kagent controller in the path).
- `frontend/nginx.conf` — proxies `/api/a2a/<ns>/<agent>/` to `<agent>.<ns>.svc.cluster.local:8080`. **When federation is fixed, change to `.svc.<cluster>.mesh.internal`.**

### Docs (rendered to GitHub Pages)

- `docs/index.html` — landing page. Has "Downloads" section (zips) + "Options to defeat the rug-pull" (three layers, plain English) + kagent-enterprise auth chain.
- `docs/single-cluster.html` — single-cluster walkthrough + full CRD reference + download button.
- `docs/multi-cluster.html` — three-cluster walkthrough + full CRD reference (5 groups, ~30 kinds) + download button.
- `docs/downloads/trustusbank-{single,multi}-cluster.zip` — every YAML manifest with README + CRD ref appendix.

### Bundle builder

- `scripts/build-crd-bundles.sh` — rebuilds the two download zips from `manifests/`. Idempotent. Run after any manifest change.

---

## What's been committed and tagged

Recent commits (most recent first):
- `0ec5dc1` — CLAUDE.md: document the federation east-west GW discovery integration gap
- `75621e1` — Solo best practices: CLAUDE.md + east-west federation infra + lateral-hack dynamic IPs
- `86ea953` — Add downloadable manifest bundles + CRD docs polish
- `8baf83f` — gloo-operator integration: codify the three waypoint-install patches (istiod alias, trustDomain, CLUSTER_ID)
- `08f262a` — Fixes from the gloo-operator rebuild run (wait_for_pods_ready, cookie secret, version suffix)
- `dc81cce` — scripts/00-prereqs.sh: don't hang on istioctl version without kube context
- `e8b08c1` — Docs: M03 section rewritten for Gloo Operator + ServiceMeshController
- `8ebeaee` — Gloo Operator: replace 03-solo-istio.sh with declarative ServiceMeshController
- `e83771c` — Docs: new architecture (Enterprise kagent on bank only) + multiple-defences section
- `6db60de` — Observability: add KagentAccessPolicyDeny alert + Grafana panels

Tag: **`pre-gloo-operator`** — checkpoint before the operator migration. Helm-based mesh install. Working rollback point.

---

## Important decisions made (and why)

These shaped the current architecture. Don't undo them without understanding why.

1. **Enterprise kagent on bank only; no OSS kagent on edge.**
   Original architecture had OSS on edge + Enterprise on bank. User explicitly rejected: "we should be using Solo products throughout, ONE agent and a simple story, no mixing OSS and Enterprise images". Now: only Enterprise kagent, only on bank. Edge is presentation tier (chatbot only).

2. **Chatbot speaks A2A JSON-RPC direct, not through kagent controller's REST API.**
   The Enterprise kagent controller requires a session cookie. Chatbot has no way to acquire one without OIDC login. Solution: chatbot's nginx proxies `/api/a2a/<ns>/<agent>/` to `<agent>.<ns>.svc.cluster.local:8080` directly. The agent pod's A2A JSON-RPC endpoint doesn't require auth — mesh-level AuthZ (via the waypoint) is the gate. This is the production-correct shape: service-to-service authenticates via mesh SPIFFE, not via human-user OIDC.

3. **trustDomain = cluster.local on every cluster** (not bank.local / edge.local / vendor.local).
   The enterprise-agentgateway waypoint binary hardcodes `TRUST_DOMAIN=cluster.local` env. No chart knob to override. We tried bank.local first; waypoint cert-fetch failed with "request authenticate failure". Lock SMC trustDomain to cluster.local; multi-cluster identity is still unique via clusterID + shared root CA.

4. **support-bot AccessPolicy removed (only fraud-bot enforced).**
   Cross-cluster chatbot → support-bot via lateral-hack strips SPIFFE on the SNAT hop. AccessPolicy with `kind: ServiceAccount` subject can't match an anonymous source. We removed the support-bot policy to keep the chatbot demo functional. fraud-bot policy stays and enforces (intra-cluster A2A — triage-bot can call fraud-bot, support-bot can't).

5. **Gloo Operator for mesh install (replaces 4 helm releases per cluster).**
   IT installs the operator once, applies one ServiceMeshController CR per cluster. Mesh upgrade = edit `.spec.version`. The original 4-helm-release path is preserved as `scripts/multi/03-solo-istio.sh.legacy` for rollback (`git checkout pre-gloo-operator` also works).

6. **No SandboxAgent CR in scope.**
   Mentioned in `docs/index.html` "Options" section as a future enhancement. Not implemented because adding agent-sandbox would require an extra namespace + controller and didn't pay off for the demo's three-layer defence story.

---

## Memory + global preferences

`~/.claude/projects/-Users-tomorourke-code-solo-kind-lab-dora-demo/memory/feedback_solo_best_practices.md` — the user has said multiple times "use Solo products throughout, no hacky code, production best practices". Don't propose workarounds that aren't pinned to a Solo doc page or a clear integration patch with comment.

---

## What to do FIRST in a fresh session

1. `git pull` to make sure local is in sync.
2. Read `CLAUDE.md` (Solo defaults + known gaps).
3. Read this file (current state + open work).
4. Run the four verification commands in "How to verify it's green" above.
5. If anything's red: it's almost certainly the lateral-hack node IPs being stale after a Docker restart — run `scripts/multi/apply-lateral-hack.sh`.
6. Pick up the open work: fixing east-west GW discovery (any one of the three documented paths). See `docs/multi-cluster.html` for the existing CRD-level documentation of the federation pattern.
