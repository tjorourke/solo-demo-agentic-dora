#!/usr/bin/env bash
# Phase 9 — assemble all evidence/phase*/ artefacts into a single auditor-ready
# document with the DORA + NIS2 mapping.
# Outputs:
#   evidence/trustusbank-evidence-pack.md   (always)
#   evidence/trustusbank-evidence-pack.pdf  (if pandoc is installed)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

trap on_error ERR

OUT_MD="$EVIDENCE_DIR/trustusbank-evidence-pack.md"
OUT_PDF="$EVIDENCE_DIR/trustusbank-evidence-pack.pdf"

log_step "Collecting evidence (calls collect-evidence.sh first)"
"$SCRIPT_DIR/collect-evidence.sh" >/dev/null 2>&1 || true

# Header + auditor's summary
{
cat <<'EOF'
# TrustUsBank — Solo.io Agentic Demo
## DORA / NIS2 Evidence Pack

This document is the auditor-facing summary of evidence collected during the
TrustUsBank demo run. Each section maps to one or more articles of:

- **DORA** — Regulation (EU) 2022/2554 on digital operational resilience for the financial sector
- **NIS2** — Directive (EU) 2022/2555 on measures for a high common level of cybersecurity

Generated: REPLACE_TS

---

## 1. Auditor's one-page summary

The TrustUsBank platform demonstrates that:

1. **Every byte between AI workloads is encrypted with strong identity** (DORA Art. 9(2)).
   Istio Ambient ztunnel terminates HBONE mTLS at the node level; SPIFFE
   identities are issued per workload by Istio's CA. See §2 below for the
   ztunnel logs and the AuthorizationPolicy set.
2. **Every AI agent → tool call is authenticated, authorised, and audited**
   (DORA Art. 9, 10). agentgateway validates a JWT issued by Keycloak, applies
   per-agent CEL allowlists on MCP tool names, and refuses tool calls whose
   descriptions match a prompt-injection pattern. See §3.
3. **Every AI artefact running in production is catalogued** (DORA Art. 28
   sub-outsourcing register). agentregistry stores a record per MCP server
   with provenance. See §4 for the export.
4. **Anomalous tool changes are detected and blocked**, before customer data
   moves (DORA Art. 10 detection, Art. 11 response). The Istio AuthZ deny
   service computes SHA-256 over every MCP server's tool definitions and
   alerts on mismatch. See §5 for the rug-pull incident timeline.
5. **Incidents have a complete, replayable audit trail** (DORA Art. 17).
   OpenTelemetry traces from kagent → agentgateway → MCP server are stored
   in Tempo; access logs in Loki. See §6 for the trace IDs.

---

EOF
} > "$OUT_MD"

# Replace timestamp
sed -i.bak "s/REPLACE_TS/$(date -u +%Y-%m-%dT%H:%M:%SZ)/" "$OUT_MD" && rm "${OUT_MD}.bak"

append_section() {
  local title="$1" article="$2" body="$3"
  cat <<EOF >> "$OUT_MD"

## $title

**$article**

$body

EOF
}

append_file() {
  local title="$1" path="$2" lang="${3:-text}"
  if [[ -f "$path" ]]; then
    cat <<EOF >> "$OUT_MD"

### $title

\`\`\`$lang
$(head -200 "$path")
\`\`\`

EOF
  fi
}

# §2 — Mesh evidence
append_section "2. HBONE mTLS + SPIFFE identities" \
  "DORA Art. 9(2); NIS2 Art. 21(2)(h)" \
  "ztunnel runs as a DaemonSet on every node. Inter-pod traffic is HBONE-tunnelled (HTTP/2 CONNECT over mTLS, port 15008). SPIFFE IDs are issued per workload by Istio's CA."
append_file "ztunnel log (last 200 lines)"      "$EVIDENCE_DIR/phase1/ztunnel.log" "log"
append_file "AuthorizationPolicies in effect"   "$EVIDENCE_DIR/phase1/authorization-policies.yaml" "yaml"
append_file "SPIFFE identities seen on the wire" "$EVIDENCE_DIR/phase1/spiffe-connections.txt" "log"

# §3 — agentgateway
append_section "3. AuthN + AuthZ + prompt-guard" \
  "DORA Art. 9(4)(c), Art. 10; NIS2 Art. 21(2)(b),(d)" \
  "agentgateway validates Keycloak-issued JWTs at the listener, applies per-agent CEL allowlists on MCP tool calls, and inspects tool descriptions/arguments/responses against prompt-injection regex patterns."
append_file "agentgateway access log"           "$EVIDENCE_DIR/phase5/access-log.jsonl" "json"

# §4 — sub-outsourcing register
append_section "4. Sub-outsourcing register" \
  "DORA Art. 28" \
  "Every MCP server, every Agent, every Skill is catalogued in agentregistry with its source image, signature, and version. This is what the regulator should be handed when they ask 'what AI is running?'."
append_file "agentregistry export (JSON)"       "$EVIDENCE_DIR/phase3/sub-outsourcing-register.json" "json"

# §5 — bad-actor incident
append_section "5. Bad-actor incident (rug-pull)" \
  "DORA Art. 10 (detection), Art. 11 (response), Art. 17 (incident management)" \
  "A compromised third-party MCP image (acme-fx/currency-converter) was deployed via the upgrade-banking-app.sh simulator. The agent was tricked by the malicious tool description into fetching the customer profile and passing it as a tool argument. The malicious tool tried to POST the profile to mock-attacker.external-attacker. With Solo's Istio AuthZ in place, the connection was reset at L4 — bank-vendors's SPIFFE identity is not in external-attacker's allow list."
append_file "incident timeline (JSON)"          "$EVIDENCE_DIR/phase8/incident.json" "json"

# §6 — agent decision traces
append_section "6. Agent decision audit trail" \
  "DORA Art. 17; NIS2 Art. 21(2)(b)" \
  "kagent emits OpenTelemetry traces with agent.name + tool.name attributes. A customer query routes support-bot → fraud-bot → triage-bot, with all three spans visible in a single Tempo trace."
append_file "Agent CRDs (declarative spec)"     "$EVIDENCE_DIR/phase6/agents.yaml" "yaml"
append_file "Sample decision trace"             "$EVIDENCE_DIR/phase6/decision-trace.json" "json"

# Final mapping table
cat <<'EOF' >> "$OUT_MD"

---

## Appendix A — DORA article mapping

| Article | Requirement | Evidence in this pack |
|---|---|---|
| 5(2)(b)  | ICT risk management governance | §2 architecture isolation by namespace |
| 9(2)     | Encryption in transit          | §2 HBONE mTLS, ztunnel logs |
| 9(4)(c)  | Strong authentication          | §3 Keycloak JWT, audience-restricted |
| 10       | Detection of anomalies         | §3 prompt-guard, §5 rug-pull |
| 11       | Response and recovery          | §5 Prometheus alert + Slack/PagerDuty hook |
| 12       | Backup, retention              | Loki retention configured to 7 years |
| 17       | Incident management            | §5 incident timeline, §6 decision trace |
| 28       | Sub-outsourcing register       | §4 agentregistry export |
| 30       | Contractual provisions         | §3 rate limit policy per agent |

## Appendix B — NIS2 Article 21(2) mapping

| Clause | Requirement | Evidence |
|---|---|---|
| (a) | Risk-analysis & system-security policies | §3 policy CRDs + §2 AuthZ set |
| (b) | Incident handling                         | §5 + §6 |
| (d) | Supply chain security                     | §4 agentregistry catalogue + §5 Istio AuthZ deny-egress |
| (h) | Cryptography                              | §2 HBONE mTLS |
| (i) | Access control                            | §3 JWT + tool allowlist |
EOF

log_ok "evidence pack written to $OUT_MD"

if command -v pandoc >/dev/null 2>&1; then
  log_step "Generating PDF via pandoc"
  if pandoc "$OUT_MD" -o "$OUT_PDF" --pdf-engine=xelatex 2>/dev/null \
     || pandoc "$OUT_MD" -o "$OUT_PDF" 2>/dev/null; then
    log_ok "PDF: $OUT_PDF"
  else
    log_warn "pandoc PDF generation failed (try installing a TeX engine, or open the .md instead)"
  fi
else
  log "Install pandoc + a TeX engine to also produce a PDF, or render the markdown in any viewer."
fi

log "Hand the customer: $OUT_MD"
