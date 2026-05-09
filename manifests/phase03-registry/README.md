# Phase 3 — agentregistry (Solo's catalog plane)

agentregistry is a **Postgres-backed REST registry** with a CLI (`arctl`).
It is **not a CRD-based controller**. There are no Kubernetes
`Artefact` / `Policy` custom resources to apply.

## What gets installed

`scripts/04-registry.sh` does:

1. `helm upgrade --install agentregistry ...` from the project's release
   tarball. The chart needs:
   - `config.jwtPrivateKey` set to a hex string (NOT a PEM key).
   - The bundled postgres overridden to `pgvector/pgvector:pg17` because
     the migrations require the `vector` extension.
2. `arctl mcp publish` for each legitimate MCP server, registering them
   under the `trustusbank/` namespace:
   - `trustusbank/account-mcp`
   - `trustusbank/transaction-mcp`
   - `trustusbank/ticket-mcp`

`acme-fx/currency-converter` (the malicious third-party tool) is
**not** registered at deploy time — that happens during the demo,
inside `./scripts/supply-chain-attack.sh`, modelling the moment a
compromised vendor pushes a release.

## What this gets you

- The **DORA Article 28 sub-outsourcing register**. `arctl mcp list`
  returns every registered MCP server with provenance, transport,
  version, description.
- OCI image label validation at registration (`io.modelcontextprotocol.server.name`).

## What it does NOT do today (verified against v0.3.x source)

- agentregistry has no MCP **client** code — it never connects out to a
  running MCP server. The catalog plane never re-checks artefacts at
  runtime.
- It does not verify cosign / sigstore signatures. Image signing is
  listed as a planned-but-unshipped gap in their CNCF self-assessment
  (`docs/governance/cncf/technical-review.md` in their repo).
- The maintainers explicitly say agentregistry *"is not a runtime
  security agent — runtime policy enforcement is delegated to
  components like the agentgateway, service meshes, or Kubernetes
  network policies."*

So the runtime fingerprinting / artefact-mutation detection that
*would* close the rug-pull gap is deliberately out of scope for
agentregistry. In production you'd plug in a separate runtime tool
(Falco, Tetragon, Sigstore policy-controller, or a SIEM watching the
registry's API) alongside Solo's three planes. The demo doesn't ship
that piece because the breach prevention happens at the network layer
in Act 2 — Istio AuthZ resets the lateral exfil before any data
moves.

## Files

| File | Purpose |
|---|---|
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
