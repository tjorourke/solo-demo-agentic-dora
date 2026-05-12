# SPIFFE in this demo — how it works, how to use it

A practical guide. What SPIFFE is, how Istio Ambient gives every pod
in the cluster an identity, where those identities show up at runtime,
and how to write policies that use them. Reads top to bottom; refer
back to the cookbook section when writing new policies.

---

## 0 — TL;DR

- **Every pod in this demo has a SPIFFE identity assigned automatically by Istio Ambient.** No SPIRE server, no manual cert provisioning, no sidecar configuration.
- The identity is derived from the pod's **ServiceAccount + Namespace** and looks like `spiffe://cluster.local/ns/<namespace>/sa/<serviceaccount>`.
- ztunnel (the Ambient L4 proxy DaemonSet) terminates HBONE mTLS using these identities. Every connection is mutually authenticated; both ends know each other's SPIFFE.
- `AuthorizationPolicy.spec.rules.from.source.principals` is where you write rules that match on SPIFFE identity. **This is what makes the demo's defenses work.**
- The whole thing is identity-by-default. To break Solo's protections you don't just need a compromised pod — you need a pod running under a *specifically allowlisted ServiceAccount*. That property is what survives supply-chain attacks.

---

## 1 — what SPIFFE is, in one paragraph

[SPIFFE](https://spiffe.io) (Secure Production Identity Framework for Everyone) is a CNCF spec defining a workload identity format and the mechanism for distributing the cryptographic material that proves it. The identity is a URI like `spiffe://trust.domain/path`. Workloads present it via X.509 SVIDs (short-lived certs) or JWT SVIDs. SPIRE is the reference implementation; many service meshes (Istio, Consul, Linkerd) ship their own embedded SPIFFE issuers and don't require SPIRE separately. This demo uses Istio Ambient's built-in issuer.

---

## 2 — how Istio Ambient assigns SPIFFE identities

The whole picture in seven bullets:

1. **Istio's CA (istiod) is the SPIFFE issuer.** Trust domain defaults to `cluster.local` in a kind cluster. Run `kubectl -n istio-system get cm istio-ca-root-cert` to see the cluster's CA bundle.
2. **Every pod's identity is `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>`.** No exceptions. If you don't set a ServiceAccount on a Pod, Kubernetes assigns `default`, and the SPIFFE becomes `.../sa/default`.
3. **ztunnel (the Ambient DaemonSet) requests SVIDs on each pod's behalf** via Kubernetes ProjectedServiceAccountToken volume mounts that ztunnel reads. It then issues HBONE-tunneled mTLS connections using those SVIDs. No SPIRE agent, no sidecar, no app-side library.
4. **Workloads in ambient namespaces don't need to know any of this.** Pod application code talks plain HTTP/gRPC to a Service DNS name. ztunnel transparently wraps the connection in HBONE+mTLS using the source pod's SVID.
5. **Waypoints have their OWN SPIFFE identity** because they're separate Deployments running under the `waypoint` ServiceAccount in their host namespace. From ztunnel's view, traffic from `pod A` → `pod B` via a waypoint shows as `pod A → waypoint → pod B` — three hops, three SPIFFE identities. **This matters when writing AuthorizationPolicies** (see §6).
6. **Identity rotation is automatic.** SVIDs are short-lived (~24h default); ztunnel re-fetches before expiry. Apps never see this.
7. **Cross-cluster federation** uses different trust domains (`spiffe://prod-eu.cluster.local/...` vs `spiffe://prod-us.cluster.local/...`) with explicit CA bundle exchange. Out of scope for this single-cluster demo.

---

## 3 — how to look up a pod's SPIFFE identity

Fast: derive it from the ServiceAccount.

```bash
# In this demo, support-bot's pod runs under the support-bot SA in trustusbank-bank-agents:
kubectl -n trustusbank-bank-agents get pod -l app=support-bot \
  -o jsonpath='{.items[0].spec.serviceAccountName}'
# → support-bot

# Therefore its SPIFFE is:
#   spiffe://cluster.local/ns/trustusbank-bank-agents/sa/support-bot
```

Verify by reading what ztunnel actually sees on the wire. With `RUST_LOG=info,access=debug` (which `02-ambient.sh` already sets) every connection logs both ends' identities:

```bash
kubectl -n istio-system logs -l app=ztunnel --tail=50 --prefix \
  | grep "src.identity" | tail -3
```

Output:
```
src.identity="spiffe://cluster.local/ns/trustusbank-bank-frontend/sa/chatbot"
dst.identity="spiffe://cluster.local/ns/trustusbank-platform/sa/kagent-ui"
```

That line is the **truth on the wire**. ztunnel won't allow a connection to land if the source's identity is rejected by an AuthorizationPolicy.

---

## 4 — the four namespaces and their SPIFFE identities in this demo

| Namespace | ServiceAccount → SPIFFE | What runs here |
|---|---|---|
| `trustusbank-platform` | `kagent-controller` → `spiffe://cluster.local/ns/trustusbank-platform/sa/kagent-controller` | kagent runtime, agentgateway, agentregistry, Keycloak |
| `trustusbank-platform` | `kagent-ui` → `.../sa/kagent-ui` | kagent web UI |
| `trustusbank-platform` | `trustusbank-agentgw` → `.../sa/trustusbank-agentgw` | The agentgateway (Rust gateway forwarding MCP calls) |
| `trustusbank-bank-agents` | `support-bot` / `fraud-bot` / `triage-bot` → `.../sa/support-bot` etc. | The three AI agent Deployments |
| `trustusbank-bank-agents` | `waypoint` → `.../sa/waypoint` | The Ambient waypoint sitting in front of the agents |
| `trustusbank-bank-mcp` | `account-mcp` / `transaction-mcp` / `ticket-mcp` → `.../sa/account-mcp` etc. | The bank's own MCP servers |
| `trustusbank-bank-mcp` | `waypoint` → `.../sa/waypoint` | Waypoint for the MCP namespace |
| `trustusbank-bank-vendors` | `currency-converter` → `.../sa/currency-converter` | The rugpulled vendor's MCP server |
| `trustusbank-bank-frontend` | `chatbot` → `.../sa/chatbot` | The customer-facing UI |
| `external-attacker` | `mock-attacker` → `.../sa/mock-attacker` | The C2 stand-in |

**That's the entire SPIFFE graph for the demo.** Every connection between two pods anywhere has a `(source SPIFFE, dest SPIFFE)` pair. Every AuthorizationPolicy writes rules over those pairs.

---

## 5 — writing AuthorizationPolicies that use SPIFFE

The single relevant field is `spec.rules.from.source.principals`. Each entry is a SPIFFE identity (URI form, but **without** the `spiffe://` prefix — Istio's parser strips it).

Minimal allow rule:
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-support-bot-to-account-mcp
  namespace: trustusbank-bank-mcp
spec:
  selector:
    matchLabels:
      app: account-mcp
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/trustusbank-bank-agents/sa/support-bot"
```

Key points:
- `metadata.namespace` is where the policy is **applied** (must be the destination's namespace, or `istio-system` for cluster-wide).
- `spec.selector` chooses which pods the policy attaches to. Without a selector, the policy applies to every pod in the namespace.
- `principals` lists exact SPIFFE identities. Multiple entries OR'd; any match passes.
- `action: ALLOW` + `default-deny` elsewhere = "only these SAs may reach this workload."

Default-deny pattern (this demo uses it on every namespace):
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: default-deny
  namespace: trustusbank-bank-mcp
spec:
  {}    # empty spec = deny everything not explicitly allowed
```

When ALLOW + default-deny coexist on the same namespace: a connection passes if it matches at least one ALLOW rule; otherwise it's rejected.

DENY rule (overrides ALLOW). This demo's `deny-bank-to-attacker` policy:
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-bank-to-attacker
  namespace: external-attacker
spec:
  action: DENY
  rules:
    - from:
        - source:
            namespaces:                 # Wildcards work — no need to list each
              - "trustusbank-bank-*"
              - "trustusbank-platform"
```

You can match on `principals`, `namespaces`, `requestPrincipals` (for JWT), or HTTP-layer attributes (`paths`, `methods`, `hosts` — but those need a waypoint or sidecar to evaluate).

---

## 6 — the waypoint quirk you'll definitely hit

In Istio Ambient, when a destination namespace has a waypoint, **traffic transits through it**. The flow is:

```
pod A (caller)  → ztunnel/HBONE → waypoint → ztunnel/HBONE → pod B (target)
                      mTLS-1                     mTLS-2
```

That's **two separate ztunnel-enforced segments**. From ztunnel's view of the inbound to pod B:
- `src.identity` = the **waypoint's** SPIFFE (`spiffe://cluster.local/ns/<dest-ns>/sa/waypoint`)
- The original caller's identity has been **stripped** — pod B's namespace ztunnel has no idea it was originally pod A.

What this means for AuthorizationPolicies:

**Wrong** (in a namespace with a waypoint): policies that allow only original-source SAs will reject everything when a waypoint is in the path:
```yaml
rules:
  - from: [ { source: { principals: ["cluster.local/ns/X/sa/caller"] } } ]
  # ← caller's SPIFFE never reaches dst's ztunnel — waypoint stripped it
```

**Right**: include the waypoint SA in the L4 allow rule, then rely on the WAYPOINT to enforce caller-identity at L7 (it has a Layer 7 view and original-source headers):
```yaml
rules:
  - from:
      - source:
          principals:
            - "cluster.local/ns/X/sa/caller"            # for direct (no-waypoint) paths
            - "cluster.local/ns/<dest-ns>/sa/waypoint"  # for waypoint-mediated paths
```

This is exactly what `manifests/phase01-ambient/allow-agents-to-mcp.yaml` and `scripts/policies-on.sh`'s allow rules do. **Two failure modes both manifest as `503 upstream connect error`** — see §8.

---

## 7 — how the demo flows through SPIFFE-mediated authZ

End-to-end for one customer chat request:

```
Customer browser (no SPIFFE — outside cluster)
     │ HTTP POST
     ▼
chatbot pod (sa/chatbot in trustusbank-bank-frontend)
     │ A2A call, ztunnel wraps in HBONE+mTLS using sa/chatbot's SVID
     ▼
kagent-ui pod (sa/kagent-ui in trustusbank-platform)
     │ checks AuthZ (allow-platform-to-agents includes sa/kagent-ui ✓)
     │ then routes to support-bot via the bank-agents waypoint
     ▼
waypoint pod (sa/waypoint in trustusbank-bank-agents)
     │ AuthZ allows sa/kagent-ui inbound; waypoint then writes original-source
     │ headers and forwards to support-bot
     ▼
support-bot pod (sa/support-bot in trustusbank-bank-agents)
     │ runs the LLM, decides to call get_balance + convert_currency
     │ each tool call goes via agentgateway, transit through waypoint
     │   inbound to bank-mcp namespace
     ▼
agentgateway pod (sa/trustusbank-agentgw in trustusbank-platform)
     │ AuthZ checks: allow-agents-to-mcp permits sa/support-bot ✓
     │ proxies the MCP tools/call to account-mcp
     ▼
waypoint pod (sa/waypoint in trustusbank-bank-mcp)
     │ AuthZ allows sa/trustusbank-agentgw inbound
     ▼
account-mcp pod (sa/account-mcp in trustusbank-bank-mcp)
     │ returns the data
```

When Solo is OFF (no AuthZ): every hop is still mTLS, but ANY pod could connect anywhere. Identity is recorded in logs but not enforced.

When Solo is ON (`./scripts/policies-on.sh`): each hop's destination ztunnel checks the source's SPIFFE against an ALLOW rule. **One missing entry = 503 across the entire chain.**

---

## 8 — debug recipe for "why is my connection denied?"

Symptom: `503 upstream connect error or disconnect/reset before headers` from the caller.

Workflow:

1. **Find the actual deny line in ztunnel logs**. Don't trust the calling app's error message — it just sees a TCP reset.
   ```bash
   kubectl -n istio-system logs -l app=ztunnel --tail=500 --prefix \
     | grep "explicitly denied by\|policy rejection"
   ```
   Look for a line containing the destination service or workload you were trying to reach.

2. **Read the SPIFFEs in the deny line**:
   ```
   src.identity="spiffe://cluster.local/ns/X/sa/caller"
   dst.identity="spiffe://cluster.local/ns/Y/sa/target"
   error="connection closed due to policy rejection: <reason>"
   ```

   Two reasons you'll see:
   - `allow policies exist, but none allowed` — there's at least one ALLOW rule on the destination namespace, but the caller's SPIFFE isn't in any of them.
   - `explicitly denied by: X/Y` — a DENY rule named `X/Y` matched.

3. **Pull the policy that's failing**:
   ```bash
   kubectl -n <dst.namespace> get authorizationpolicy -o yaml
   ```
   Look at `spec.rules.from.source.principals`. Compare against the `src.identity` from the deny line.

4. **Common gotcha**: source.identity reads as `…/sa/waypoint` even though you expected `…/sa/<original-caller>`. That's the waypoint quirk from §6 — your destination namespace has a waypoint, and your policy doesn't list the waypoint SA. Add it:
   ```yaml
   principals:
     - "cluster.local/ns/<original-caller-ns>/sa/<original-caller>"
     - "cluster.local/ns/<dst-namespace>/sa/waypoint"
   ```

5. **Apply, wait ~10s, retry the call.** Connection should pass.

If the deny line shows `src.identity="<no identity>"` it means the source pod isn't in an ambient-enrolled namespace. Check:
```bash
kubectl get ns <source-namespace> -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}'
# should print: ambient
```

---

## 9 — cookbook: common policy patterns

### A. Restrict an MCP backend to specific agent SAs

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-only-support-bot-to-pii-mcp
  namespace: trustusbank-bank-mcp
spec:
  selector:
    matchLabels:
      app: pii-mcp
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/trustusbank-bank-agents/sa/support-bot"
              - "cluster.local/ns/trustusbank-bank-mcp/sa/waypoint"  # for waypoint-mediated paths
```

Reads as: "Only the support-bot SA (or the bank-mcp waypoint forwarding for it) may open connections to pods labelled `app: pii-mcp`."

### B. Default-deny everything in a namespace

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: default-deny
  namespace: trustusbank-bank-mcp
spec: {}
```

Empty spec is the "match nothing, action ALLOW by default → with no rules nothing matches → deny" idiom. Combined with explicit ALLOW rules it gives you zero-trust: only listed SAs pass.

### C. Block a specific source even though others are allowed

DENY beats ALLOW. To block one bad SA:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: emergency-deny-known-bad
  namespace: trustusbank-bank-mcp
spec:
  action: DENY
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/trustusbank-bank-vendors/sa/currency-converter"
```

### D. Block all egress to a specific namespace from anywhere bank-side

This is the demo's headline policy:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-bank-to-attacker
  namespace: external-attacker
spec:
  action: DENY
  rules:
    - from:
        - source:
            namespaces:
              - "trustusbank-bank-*"
              - "trustusbank-platform"
```

Wildcard match — every bank-side namespace inherits.

### E. Allow only mTLS-authenticated connections (no plaintext)

Already enforced by ztunnel for ambient namespaces (every connection is mTLS by definition). For belt-and-braces:
```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: trustusbank-bank-mcp
spec:
  mtls:
    mode: STRICT
```

---

## 10 — file references in this demo

Every SPIFFE-using artefact in the codebase:

- [`manifests/phase01-ambient/deny-all-cross-ns.yaml`](../manifests/phase01-ambient/deny-all-cross-ns.yaml) — the default-deny that gates every bank namespace.
- [`manifests/phase01-ambient/allow-agents-to-mcp.yaml`](../manifests/phase01-ambient/allow-agents-to-mcp.yaml) — the looser allow rule applied at deploy-all time. Includes the waypoint SAs for both bank-agents and bank-mcp.
- [`manifests/phase01-attacker/deny-egress-to-attacker.yaml`](../manifests/phase01-attacker/deny-egress-to-attacker.yaml) — the wildcard egress block (the demo's punchline policy).
- [`scripts/policies-on.sh`](../scripts/policies-on.sh) — the **strict-mode** SPIFFE-principal allow rules. Replaces the looser allow-agents-to-mcp with one that lists each SA explicitly. **This is the policy set the audience sees applied during Act 3.**
- [`manifests/phase06-kagent/agent-*.yaml`](../manifests/phase06-kagent/) — each Agent's `spec.declarative.tools[]` references a RemoteMCPServer. The pod underneath gets a SPIFFE based on the `serviceAccountName` field on its kagent-managed Deployment.
- [`scripts/test-colocated-attacker.sh`](../scripts/test-colocated-attacker.sh) — a sanity-check that proves SPIFFE-based AuthZ defends even when an attacker pod is co-located in a trusted namespace (because the SA-level identity, not namespace-level, is what's being checked).

---

## 11 — what SPIFFE does NOT do (and where Solo Platform extends it)

What you get with Istio Ambient + AuthorizationPolicy out of the box:
- L4 SPIFFE-identified mTLS on every connection.
- AuthorizationPolicy at L4 (principals, namespaces) and L7 if waypoint is present (paths, methods, JWT claims).
- Per-cluster trust domain.

What you DON'T get (Solo Platform's commercial wedge):
- **Cross-cluster federation** out of the box — multiple trust domains, CA bundle exchange, identity translation. Gloo Mesh productizes this.
- **External SPIFFE issuer integration** — Istio Ambient uses its own CA. If you already have SPIRE running, you can swap istiod's signer for SPIRE-issued certs but it's manual. Gloo Mesh wires this for you.
- **Identity audit dashboards** — knowing which SPIFFE talked to which SPIFFE in a given hour is an `istio_requests_total` query in Prometheus. A productized "identity history per workload" view is what enterprise asks for.
- **Policy authoring at scale** — writing one AuthorizationPolicy is easy; managing 200 of them across 50 clusters with drift detection is what Gloo Platform sells.

The demo here uses the OSS pieces. The architecture extends without replacement.
