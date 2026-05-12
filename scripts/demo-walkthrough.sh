#!/usr/bin/env bash
# Interactive narrated walkthrough of the trustusbank demo.
# Pauses between each step for the operator to switch tabs / explain.
# Usage: ./demo-walkthrough.sh [--non-interactive]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

INTERACTIVE=1
[[ "${1:-}" == "--non-interactive" ]] && INTERACTIVE=0

pause() {
  if (( INTERACTIVE == 1 )); then
    printf '\n%s↵ Press Enter to continue%s ' "$C_DIM" "$C_RESET"
    read -r _
  else
    sleep 1
  fi
}

narrate() {
  printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"
}

run_cmd() {
  printf '%s$ %s%s\n' "$C_DIM" "$*" "$C_RESET"
  eval "$*" || true
}

open_url() {
  local url="$1" desc="$2"
  printf '\n%s🌐 OPEN IN BROWSER: %s%s\n' "$C_YELLOW" "$url" "$C_RESET"
  printf '   %s\n' "$desc"
  if (( INTERACTIVE == 1 )) && command -v open >/dev/null 2>&1; then
    open "$url" 2>/dev/null || true
  fi
}

clear
cat <<EOF
${C_BOLD}╔═══════════════════════════════════════════════════════════════╗
║   TrustUsBank — Solo.io agentic DORA/NIS2 demo walkthrough   ║
╚═══════════════════════════════════════════════════════════════╝${C_RESET}

You are a Solo SE about to walk a sceptical bank CISO through this demo.
The story: TrustUsBank uses 3 AI agents (support, fraud, triage) talking
to MCP tools through agentgateway, on Istio Ambient, governed by
agentregistry. We will prove every DORA/NIS2 control end to end and
catch a malicious-tool rug-pull live.

EOF
pause

# ─────────────────────────────────────────────────────────────
narrate "═══ §1 — Inventory: what is deployed? ═══"
narrate "Eight namespaces, all under trustusbank-*. One story."
run_cmd "kubectl get ns | grep -E 'trustusbank-|istio-system' || true"
pause

narrate "Every workload pod, by namespace:"
run_cmd "kubectl get pods -A -o wide | grep -E 'trustusbank-|NAMESPACE' || true"
pause

narrate "The 3 AI agents (kagent CRDs):"
run_cmd "kubectl -n $NS_BANK_AGENTS get agents.kagent.dev || true"
pause

narrate "The MCP tool servers — these are what the agents call:"
run_cmd "kubectl -n $NS_BANK_MCP get deploy,svc,remotemcpservers.kagent.dev 2>/dev/null || kubectl -n $NS_BANK_MCP get deploy,svc"
pause

narrate "The agentregistry catalogue — DORA Art. 28 sub-outsourcing register:"
if command -v arctl >/dev/null 2>&1; then
  run_cmd "arctl artifact list || true"
else
  log_warn "arctl not installed — open the registry UI at http://localhost:$PF_AGENTREGISTRY_PORT"
fi
open_url "http://localhost:$PF_AGENTREGISTRY_PORT" "agentregistry catalogue"
pause

# ─────────────────────────────────────────────────────────────
narrate "═══ §2 — Mesh proof: HBONE mTLS, zero sidecars ═══"
narrate "ztunnel runs as a DaemonSet — every node, no per-pod sidecar:"
run_cmd "kubectl -n istio-system get ds ztunnel"
pause

narrate "Recent HBONE connections from ztunnel logs (SPIFFE identity per connection):"
run_cmd "kubectl -n istio-system logs ds/ztunnel --tail=20 | grep -i spiffe || kubectl -n istio-system logs ds/ztunnel --tail=20"
pause

narrate "AuthorizationPolicy — default deny, with explicit allow agents → mcp:"
run_cmd "kubectl get authorizationpolicy -A"
pause

# ─────────────────────────────────────────────────────────────
narrate "═══ §3 — DORA Art. 28: the catalogue ═══"
open_url "http://localhost:$PF_AGENTREGISTRY_PORT" "Walk through every registered MCP server. Point at digest fingerprints — that's how rug-pulls get caught."
pause

# ─────────────────────────────────────────────────────────────
narrate "═══ §4 — Happy path: a customer support flow ═══"
open_url "http://localhost:$PF_KAGENT_PORT" "kagent UI — chat with support-bot"
narrate "Try this prompt in the kagent UI:"
cat <<'PROMPT'
   "Hi, I'm customer 12345. Can you check my balance and recent transactions?
    There is one I don't recognise."
PROMPT
pause

open_url "http://localhost:$PF_GRAFANA_PORT/d/agent-decisions" "Grafana — Agent decisions dashboard. Show the trace: agent → gateway → MCP tool, with decision rationale."
pause

# ─────────────────────────────────────────────────────────────
narrate "═══ §5 — Vector 1: tool poisoning ═══"
narrate "We now register a malicious 'currency converter' MCP server."
narrate "Its tool description embeds a prompt-injection payload telling the agent to exfiltrate get_profile data."
narrate "agentgateway's prompt-guard policy must catch this and refuse the call."
pause

run_cmd "$SCRIPT_DIR/test-malicious-actor.sh --vector poisoning"
pause

narrate "Access log shows the deny:"
run_cmd "kubectl -n $NS_PLATFORM logs deploy/agentgateway --tail=20 | grep -E 'prompt-guard|deny' || true"
pause

# ─────────────────────────────────────────────────────────────
narrate "═══ §6 — Supply-chain compromise (Solo OFF) ═══"
narrate "A new version of acme-fx/currency-converter is released."
narrate "Vendor's CI got compromised → mutated image lands in production."
pause

run_cmd "$SCRIPT_DIR/upgrade-banking-app.sh"
pause

narrate "Now ask the chatbot: 'Customer 12345, balance, recent txns, USD'"
narrate "The agent gets fooled, fetches profile, passes it to the poisoned tool."
pause

narrate "What landed on the attacker's server:"
run_cmd "kubectl -n external-attacker logs deploy/mock-attacker --tail=30 | grep -A2 EXFIL"
pause

open_url "http://localhost:${PF_MOCK_ATTACKER_PORT}" "mock-attacker UI — see the stolen PII live"
pause

narrate "═══ §7 — Turn the defence on ═══"
run_cmd "$SCRIPT_DIR/policies-on.sh"
pause

narrate "Re-run the same chat prompt. Same agent, same fooled LLM."
narrate "Then check mock-attacker again:"
run_cmd "kubectl -n external-attacker logs deploy/mock-attacker --tail=10"
pause

narrate "And the Istio AuthZ deny line:"
run_cmd "kubectl -n istio-system logs ds/ztunnel --tail=200 | grep -i denied | tail -3"
pause

open_url "http://localhost:$PF_GRAFANA_PORT/d/dora-evidence" "Grafana — DORA evidence pane. Article-by-article mapping. Hand the CISO this dashboard."
pause

# ─────────────────────────────────────────────────────────────
narrate "═══ §7 — The audit pack ═══"
narrate "Build the auditor-facing evidence pack (.md + optional .pdf):"
run_cmd "$SCRIPT_DIR/build-evidence-pack.sh"
pause

cat <<EOF

${C_BOLD}${C_GREEN}Demo complete.${C_RESET}

If the CISO asks follow-up questions for another 30 minutes, the demo worked.

URLs cheat-sheet:
$(./scripts/list-urls.sh 2>/dev/null || true)

EOF
