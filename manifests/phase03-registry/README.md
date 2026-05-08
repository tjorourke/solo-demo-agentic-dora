# Phase 3 — agentregistry

agentregistry is **not a CRD-based controller**. It is a Postgres-backed REST
registry server with a CLI (`arctl`). There are no Kubernetes Policy/Artifact
custom resources to apply.

The phase 3 script (`scripts/04-registry.sh`) does its work via:

1. `helm install` of the `agentregistry` chart (server + Postgres)
2. `arctl apply -f <artefact>.yaml` to register MCP server records
3. The demo's own digest-tracking sidecar, since rug-pull detection on the
   tool-definition layer is not a confirmed shipped feature in agentregistry
   v0.3.x — we replicate it locally for the demo (see
   `scripts/lib/digest-watch.sh`).

The artefact YAMLs that get applied via `arctl` live in `./artefacts/`
alongside this README.
