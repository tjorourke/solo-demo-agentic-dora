#!/usr/bin/env bash
# Phase 0 — verify prerequisites.
# Tasks 0.1, 0.2 from the plan.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"
trap on_error ERR

log_step "0.1 — verify CLIs"
REQUIRED=(kubectl helm docker curl python3 jq)
[[ "$CLUSTER_KIND" == "kind" ]] && REQUIRED+=(kind)
[[ "$CLUSTER_KIND" == "eks" ]]  && REQUIRED+=(eksctl aws)
require_cmd "${REQUIRED[@]}"

OPTIONAL=(istioctl arctl kagent cosign)
for c in "${OPTIONAL[@]}"; do
  if command -v "$c" >/dev/null 2>&1; then
    log_ok "$c: $($c version 2>&1 | head -1 || echo present)"
  else
    log_warn "$c not installed — install before deploy-all reaches its phase"
  fi
done

log_step "0.2 — verify ANTHROPIC_API_KEY"
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  die "ANTHROPIC_API_KEY not set. export ANTHROPIC_API_KEY=sk-ant-..."
fi
key_len=${#ANTHROPIC_API_KEY}
if (( key_len < 30 )); then
  die "ANTHROPIC_API_KEY looks truncated (length=$key_len)"
fi
log_ok "ANTHROPIC_API_KEY set (length=$key_len)"

log_step "Verifying repository structure"
for d in scripts manifests mcp-servers grafana-dashboards; do
  [[ -d "$REPO_ROOT/$d" ]] || die "missing $d/ — repo not initialised correctly"
done
log_ok "repo layout OK"

log_ok "Phase 0 prerequisites satisfied"
