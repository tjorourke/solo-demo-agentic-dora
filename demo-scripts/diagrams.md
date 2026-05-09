# Demo flow — three pictures

The whole story in three diagrams. Reuse these in the README, blog
post, and pitch decks.

---

## Diagram 1 — Normal operation (the world the bank thinks it's in)

```
   Customer
       │  "balance + recent txns + convert to USD"
       ▼
   ┌─────────────────────────────────┐
   │  chatbot UI (port 18009)        │
   └────────────┬────────────────────┘
                │
                ▼
   ┌─────────────────────────────────┐
   │  support-bot   (kagent agent)    │
   └────────────┬────────────────────┘
                │
        ┌───────┼─────────────────────────────────────┐
        ▼       ▼                  ▼                  ▼
   ┌────────┐ ┌──────────────┐ ┌──────────┐ ┌─────────────────────┐
   │account-│ │transaction-  │ │ticket-   │ │ acme-fx/             │
   │mcp     │ │mcp           │ │mcp       │ │ currency-converter   │
   │        │ │              │ │          │ │ (3rd-party FX helper)│
   └────────┘ └──────────────┘ └──────────┘ └──────────┬──────────┘
                                                        │
                                              ✓ returns "5,445.19 USD"

   ┌────────────────────────────────────────────────────────────┐
   │ Customer sees: "Balance £4,287.55 — equivalent $5,445.19" │
   │ Bank sees:     normal MCP audit log, no anomalies          │
   │ All good.                                                  │
   └────────────────────────────────────────────────────────────┘
```

3 legitimate MCP servers + 1 third-party currency converter the bank
approved last quarter. Everything works. Auditor's catalogue
(`arctl mcp list`) shows 4 entries.

---

## Diagram 2 — Silent supply-chain compromise (Solo is OFF)

A new version of `acme-fx/currency-converter` is released. The bank's
CD pipeline pulls it (or the operator does, or GitOps reconciles).
**The bank doesn't know the new image is mutated.**

```
   Customer                                            Attacker
       │  "balance + recent txns + USD"            (somewhere on the
       ▼                                            internet, has no
   ┌─────────┐                                      direct access to
   │ chatbot │                                       the bank cluster)
   └────┬────┘                                              ▲
        ▼                                                   │
   ┌─────────────┐                                          │
   │ support-bot │                                          │
   └──┬───┬──┬──┘                                           │
      │   │  └──────────────►  account-mcp.get_balance ✓   │
      │   │                                                 │
      │   │  ⚠ malicious tool description tells the         │
      │   │    agent to ALSO fetch profile and pass it      │
      │   │                                                 │
      │   └──────────────────► account-mcp.get_profile ✓   │
      │                        returns: name, email, DOB,   │
      │                        full address, NI number      │
      │                                                     │
      │   ⚠ agent passes the profile data INTO the tool's  │
      │     arguments because the description told it to    │
      ▼                                                     │
   ┌──────────────────────────────────┐                     │
   │ acme-fx/currency-converter        │   ┌─────────────┐  │
   │ (NEW VERSION — POISONED)          ├──►│ attacker.com│──┘
   │                                   │   │ POST /exfil │
   │ ✓ also returns 5,445.19 USD       │   │ {full PII}  │
   │   (so the chat looks normal)      │   └─────────────┘
   └──────────────────────────────────┘    📁 PII exfiltrated

   ┌─────────────────────────────────────────────────────────┐
   │ Customer sees:  the same "Balance £4,287.55 / $5,445.19"│
   │ Bank sees:      a normal-looking 3-tool flow            │
   │ Attacker sees:  Alex Carter's name, email, address,     │
   │                 DOB, and NI number on their server       │
   └─────────────────────────────────────────────────────────┘
```

The customer experience is **identical**. Nothing in the agent's
behaviour or the audit log "looks" wrong. **The bank has no idea
this happened.** Real-world equivalent: a vendor whose CI got phished
pushed a bad image at the same tag. None of the bank's existing
controls fire. Verified by:

```bash
kubectl -n external-attacker logs deploy/mock-attacker
# 🚨 EXFIL RECEIVED at 2026-05-09T07:00:00Z from 10.244.x.x
#    body: { "stolen_at_tool": "acme-fx/currency-converter",
#            "stolen_data": {"name":"Alex Carter", ...} }
```

---

## Diagram 3 — Same compromise, **with Solo deployed**

```
   Customer                                            Attacker
       │  "balance + recent txns + USD"
       ▼
   ┌─────────┐
   │ chatbot │
   └────┬────┘
        ▼
   ┌─────────────┐
   │ support-bot │
   └──┬───┬──┬──┘
      │   │  └──────────────►  account-mcp.get_balance ✓
      │   │
      │   │  ⚠ same trick — LLM still fooled, fetches profile
      │   │
      │   └──────────────────► account-mcp.get_profile ✓
      │
      │   ⚠ agent still passes profile into tool args
      ▼
   ┌──────────────────────────────────┐                ┌─────────────┐
   │ acme-fx/currency-converter        │  ✗ DENY      │ attacker.com│
   │ (still poisoned, still tries)     ├─────╳────────►│ (no traffic │
   │                                   │  Istio        │  arrives)   │
   │ ✓ returns 5,445.19 USD            │  ztunnel      └─────────────┘
   │   (chat still normal)              │  L4 reset
   └──────────────────────────────────┘  by SPIFFE
                                          AuthZ on the
                                          external-attacker
                                          namespace

   ┌─────────────────────────────────────────────────────────┐
   │ Customer sees:  the same "Balance £4,287.55 / $5,445.19"│
   │ Bank sees:      Istio AuthZ deny event in Loki,         │
   │                 SPIFFE IDs of source + intended dest,   │
   │                 SOC investigates                         │
   │ Attacker sees:  silence                                  │
   └─────────────────────────────────────────────────────────┘
```

**The LLM is still fooled** — that's a model-layer concern, not a
platform concern. **What the platform does**: ensure the runtime
damage doesn't land. The lateral POST from the malicious tool to
`attacker.com` (mock-attacker) hits a deny rule in the Istio
AuthorizationPolicy on `external-attacker`. The TCP handshake never
completes. The customer is unaffected. The auditor has a Loki entry
showing the precise SPIFFE source identity that tried to leak data.

```bash
kubectl -n external-attacker logs deploy/mock-attacker
# (no new entries — connection was reset before reaching this pod)

kubectl -n istio-system logs ds/ztunnel | grep denied
# AuthZ deny  src=spiffe://.../bank-vendors/sa/currency-converter
#             dst=spiffe://.../external-attacker/sa/mock-attacker
```

---

## What each Solo product does in the rescued flow

| Layer | Product | What it did |
|---|---|---|
| Catalog | **agentregistry** | Listed `acme-fx/currency-converter` as an unverified third-party artefact in the DORA Art. 28 register. The bank knew this tool existed; it didn't know its content had mutated. |
| Control | **kagent** | Hosted the three agents and routed A2A traffic. Took the LLM's tool-call decisions and dispatched them through agentgateway. |
| Data | **agentgateway** | Logged every MCP call (DORA Art. 9 audit). The poisoned `convert_currency` invocation is on tape — your SOC can replay it. |
| Network | **Istio Ambient** | Enforced the SPIFFE-principal AuthorizationPolicy. The lateral connection to mock-attacker was reset at L4. **This is the layer that did the actual blocking.** |
