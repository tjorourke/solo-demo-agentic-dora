# secrets/ — local license files

Drop your Solo product license files here. The folder is gitignored
(`secrets/*.lic`, `*.jwt`, `*.key`) so nothing here gets committed.

## Expected files

One file per product. Each file contains **just the raw JWT license string**
on a single line (no leading/trailing whitespace, no `key:` prefix).

| Filename | Product | Currently needed for | Notes |
|---|---|---|---|
| `solo-istio.lic` | Solo Enterprise for Istio | **MultiCluster feature** (cross-cluster federation, SE/WE auto-gen) | Trial license has `product: gloo-trial` and `addOns: []` — appears not to unlock MultiCluster on this build, see below |
| `solo-mesh.lic` | Solo Enterprise for Istio (Solo Mesh mgmt-server) | Workspace, AccessPolicy, federation translator | Used by `gloo-mesh-mgmt-server` on the bank cluster |
| `agentgateway.lic` | Solo Enterprise for agentgateway | Enterprise waypoint binary, AgentgatewayPolicy enforcement | Optional — fallback is OSS agentgateway |
| `kagent.lic` | Solo Enterprise for kagent | kagent controller, RemoteMCPServer, Agent CRD | Used by the 3 agents on the bank cluster |

## How the install scripts use them

`scripts/multi/00-prereqs.sh` reads each file (if present), exports it as the
matching env var, and downstream phase scripts materialise each as a
`Secret` in the right namespace AND wire it into the consuming Deployment.

```
secrets/solo-istio.lic    → SOLO_ISTIO_LICENSE_KEY
secrets/solo-mesh.lic     → SOLO_MESH_LICENSE_KEY
secrets/agentgateway.lic  → AGENTGATEWAY_LICENSE_KEY
secrets/kagent.lic        → KAGENT_LICENSE_KEY
```

## Why MultiCluster needs a real (non-trial) license

The current `.env` SOLO_ISTIO_LICENSE_KEY decodes to a JWT with
`product: gloo-trial`, `addOns: []`. istiod-gloo logs
`"license state initialized: UNSET"` and
`"SKIPPING FEATURE MultiCluster due to licensing issue: license key was not set"`
even when this license is delivered via `LICENSE_KEY` env var OR
volume-mounted at `/etc/license-keys/gloo-trial-license-key`. The MultiCluster
feature appears to require an enterprise license OR a trial license with the
`multicluster` addon explicitly granted.

If you have an enterprise (non-trial) `solo-istio.lic`, drop it here and
re-run `scripts/multi/deploy-all.sh` — the cross-cluster SE/WE auto-generation
should light up.

## Bypassing if you don't have the right license

If MultiCluster can't be unlocked, the demo runs via the documented
"lateral-hack" path (NodePort + manual EndpointSlices). See
`scripts/multi/apply-lateral-hack.sh` and `CLAUDE.md` "Known integration gaps".
