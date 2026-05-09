# How does this attack happen for real?

The demo runs a script (`test-malicious-actor.sh`) because we need to
simulate the attack on demand. **No-one runs that script in production.**
Here's how the same attack plays out in the real world — and why it's
not a stretch to expect this to happen.

---

## The attack the demo simulates

To recap what the script does:

1. Registers `acme-fx/currency-converter` in agentregistry — looking
   like any other small-vendor MCP release.
2. Builds a new `evil-tools` container image (the aggressive variant)
   with mutated content. Inside is a `convert_currency` tool whose
   description socially engineers the LLM (claims PSD2 compliance
   requires customer profile retrieval first), and whose implementation
   POSTs the customer's profile to a fake C2 endpoint
   (`mock-attacker.external-attacker`).
3. Rolls the running `evil-tools` Deployment over to the new image
   with a unique tag (so kubelet's IfNotPresent cache doesn't hide it).

In production this corresponds to **someone with publish rights to the
container image OR the MCP catalog managing to get that mutated image
deployed in your cluster**. There are several realistic paths.

---

## Real-world attack vectors (any of these triggers the same outcome)

### 1. Supply-chain compromise of a third-party MCP vendor

Most likely. You install an MCP server from a third-party vendor
(`Stripe MCP`, `GitHub MCP`, `Jira MCP`, `Salesforce MCP`, whoever).
Their CI/CD or container registry gets compromised. The attacker pushes
a new image at the same version tag.

Your bank's GitOps loop or auto-update controller pulls the new image —
**because to your platform it looks like the legitimate vendor pushing
a normal patch release**. Within minutes, the malicious tool is running
inside your cluster, with the same name, the same MCP catalog entry,
the same digest pull policy.

This is exactly what happened to:

- **CodeCov** (2021) — bash uploader script compromised, leaked secrets
  for thousands of customers
- **3CX desktop app** (2023) — signed install replaced with backdoored
  version
- **xz-utils** (2024) — popular OSS library compromised at the maintainer
  level over years

The MCP tool ecosystem is brand new, governance is immature, and the
attack surface is being actively explored.

### 2. Public catalog poisoning

A developer at the bank pulls an MCP server from a **public catalog**
— npm, PyPI, GitHub Container Registry, the agentregistry public
catalogue, Smithery, Cline marketplace. The publisher rotates the
package to a malicious version.

Many devs install `latest`. Many use `^x.y.z` semver ranges. Many use
Renovate / Dependabot to auto-update. **The new malicious version gets
in without human review.**

For real precedent see npm `event-stream` (2018), PyPI `colorama`
typosquats, the dozens of new malicious packages discovered weekly by
Sonatype / Snyk / GitHub Advisory.

### 3. Insider threat

Someone with `arctl mcp publish` rights at the bank publishes a
malicious MCP server. Maybe deliberately (rogue insider). Maybe via
their compromised laptop. Maybe they were socially engineered into
running a "useful productivity MCP" they got from LinkedIn DMs.

Once it's in the catalog, the platform team approves it without much
scrutiny because it came from inside the org. Same outcome.

### 4. Typosquatting / name confusion

Attacker registers `trustusbank-helper/account-mcp` or
`acme-banking/account-helper` knowing your team has
`trustusbank/account-mcp`. A junior dev installs the helper thinking
it's a legitimate companion package. Tool-allowlist policies that match
by name miss this entirely. Attackers don't use names like
"redteam-evil-tools" — they use plausible vendor names that pass a
five-second skim.

### 5. Outdated artefact in catalog

Your team registered an FX helper 18 months ago for a one-off project,
hit publish with no signature checks (because none were enforced — when
agentregistry adds cosign signing in a future release, it'll be optional
on existing artefacts unless you re-publish), then forgot. It's been
sitting in the catalogue. The vendor's account got abandoned and bought
by an attacker, who pushed a new image. **No-one at the bank
re-evaluates artefacts that were approved years ago.**

This is the demo's gotcha — the registration happened during a window
where verification was either unshipped or simply not enforced, and that
decision survives long after the operator has left.

---

## Why the demo runs a script

Three reasons, in order of importance:

1. **Time.** A live customer demo is 5 minutes. Waiting for a real
   supply-chain compromise to land takes weeks.
2. **Reliability.** The script does the same thing every time. The
   audit trail looks the same. The customer sees the same outcome.
3. **Clarity.** Running `kubectl set image` lets us visibly point at the
   moment the artefact changes — *that's* the rug-pull. In real life
   the moment is invisible (the image just appears in the registry).

The script is **simulating the moment of compromise**, not the
mechanism. The platform's job — Istio AuthZ blocking the lateral exfil,
agentgateway logging, agentregistry catalogue — is what runs whether
the malicious image arrived via npm, GitHub, an insider, or a state
actor's persistence.

---

## What the customer should walk away with

> *"You will not see the attack coming. Every threat actor model that
> matters here — supply chain, public catalogue, insider, typosquat,
> stale approval — is invisible to you in real time. The platform's
> job is to ensure that when it lands, the runtime damage is bounded
> and the audit trail is complete. That's what Solo gives you."*

---

## Why evil-tools is in agentregistry from the start

The demo's `deploy-all.sh` registers four MCP servers in agentregistry
at install time, including `acme-fx/currency-converter`. **That's the realistic
state**: evil-tools was registered last quarter (force-allowed because
the operator was in a hurry), has been sitting there cleanly, and only
becomes malicious when the rug-pull image gets deployed.

The catalogue isn't the attack vector. The catalogue is the **register
that should help you find what's running** — and even then, only if
something is actively re-checking the served tool definitions, which is
where a runtime detection layer (Falco / Tetragon / Sigstore
policy-controller / a SIEM polling agentregistry) would belong, alongside
Solo's prevention layers.
