#!/usr/bin/env bash
# Print all configured port-forward URLs and their alive/dead status.
# No side effects — read-only.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/common.sh"

if [[ ! -f "$PF_URLFILE" ]]; then
  log_warn "no port-forward URL file at $PF_URLFILE — run ./scripts/port-forward.sh first"
  exit 0
fi

printf '\n%sTrustUsBank demo URLs%s\n' "$C_BOLD" "$C_RESET"
printf '%s──────────────────────%s\n\n' "$C_DIM" "$C_RESET"

while IFS= read -r line; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "$line" ]] && continue
  # Extract pid=NNNN
  pid=$(echo "$line" | sed -nE 's/.*pid=([0-9]+).*/\1/p')
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    status="${C_GREEN}✓ alive${C_RESET}"
  else
    status="${C_RED}✗ dead ${C_RESET}"
  fi
  printf '%b  %s\n' "$status" "$line"
done < "$PF_URLFILE"

printf '\n%sCommands:%s\n' "$C_BOLD" "$C_RESET"
printf '  ./scripts/port-forward.sh        # restart all port-forwards\n'
printf '  ./scripts/demo-walkthrough.sh    # narrated demo run\n'
printf '  ./scripts/test-malicious-actor.sh # rug-pull demo\n\n'
