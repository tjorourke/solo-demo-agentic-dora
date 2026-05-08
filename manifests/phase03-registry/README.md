# Phase 3 — agentregistry (Solo's catalog plane)

agentregistry is a **Postgres-backed REST registry** with a CLI (`arctl`).
It is **not a CRD-based controller**. There are no Kubernetes
`Artefact` / `Policy` custom resources to apply.

## What gets installed

`scripts/04-registry.sh` does:

1. `helm upgrade --install agentregistry ...` from the project's release
   tarball. The chart needs:
   - `config.jwtPrivateKey` set to a hex string (NOT a PEM key — yes, the
     name is misleading).
   - The bundled postgres overridden to `pgvector/pgvector:pg17` because
     the migrations require the `vector` extension and the default
     `postgres:18` doesn't ship it.
2. `arctl mcp publish` for each MCP server, registering them under
   meaningful namespaces:
   - `trustusbank/account-mcp`
   - `trustusbank/transaction-mcp`
   - `trustusbank/ticket-mcp`
   - `redteam/evil-tools` (with a description flagging "UNTRUSTED signer")
3. The `digest-watcher` Deployment + Service + ConfigMaps
   (`digest-baselines`, `digest-mismatches`) + ServiceMonitor.

## What this gets you

- The **DORA Article 28 sub-outsourcing register**. `arctl mcp list`
  returns every MCP server with provenance, transport, version,
  description.
- Cosign signature verification at registration (when `signing.required`
  is set on a future agentregistry release, or via the `--allow-unsigned`
  override gotcha).

## What it does NOT do today (and what fills the gap)

agentregistry v0.3.x does not recompute SHA-256 over the served
`tools/list` payload at runtime. So an attacker who pushes a new image
with the same tag — a "rug-pull" — gets past the registry, because the
artefact was already approved.

The `digest-watcher` service in `services/digest-watcher/` fills that
gap as a roadmap prototype. It polls each MCP server every 30 seconds,
hashes the tool definitions, and alerts on mismatch. The control is
real; only the placement (sidecar service vs catalog-plane feature) is
provisional.

In the demo runbook, agentregistry plays the role of "the catalog —
which is what the auditor reads", and digest-watcher plays the role of
"the runtime canary — which is what the SRE alerts on." Both are needed
for a complete DORA Article 10 + 28 story.

## Files

| File | Purpose |
|---|---|
| `digest-watcher.yaml` | The custom prototype service deployment + RBAC + Service + ConfigMaps + ServiceMonitor |
| `artefacts/*.yaml` | Reference artefact records — used to be `arctl apply` input but the current arctl uses `arctl mcp publish` instead. Kept as documentation of the intended catalog state. |

## Operator commands you'll actually run

```bash
# port-forward the registry locally
kubectl -n trustusbank-platform port-forward svc/agentregistry 18006:12121

# point arctl at it
export ARCTL_API_BASE_URL=http://localhost:18006

# list the catalogue — this is what the auditor sees
arctl mcp list

# publish a new artefact
arctl mcp publish trustusbank/my-new-mcp --version 1.0.0 --type oci \
  --package-id localhost:5001/myorg/my-mcp:1.0.0 \
  --transport streamable-http \
  --description "What this tool does, in plain English"

# show details
arctl mcp show trustusbank/my-new-mcp --version 1.0.0
```
