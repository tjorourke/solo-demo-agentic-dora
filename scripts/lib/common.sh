#!/usr/bin/env bash
# Shared helpers — logging, idempotent k8s/helm wrappers, retry, port-forward primitives.
# Source from other scripts; do not run directly.

set -Eeuo pipefail

# Colours (skip if not a TTY)
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

log()      { printf '%s[%s]%s %s\n' "$C_BLUE" "$(date +%H:%M:%S)" "$C_RESET" "$*" >&2; }
log_ok()   { printf '%s[%s] ✓%s %s\n' "$C_GREEN" "$(date +%H:%M:%S)" "$C_RESET" "$*" >&2; }
log_warn() { printf '%s[%s] ⚠%s %s\n' "$C_YELLOW" "$(date +%H:%M:%S)" "$C_RESET" "$*" >&2; }
log_err()  { printf '%s[%s] ✗%s %s\n' "$C_RED" "$(date +%H:%M:%S)" "$C_RESET" "$*" >&2; }
log_step() { printf '\n%s%s═══ %s ═══%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET" >&2; }

die() { log_err "$*"; exit 1; }

# require_cmd cmd1 cmd2 ...
require_cmd() {
  local missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    die "missing required CLIs: ${missing[*]}"
  fi
}

# retry <attempts> <sleep_seconds> -- <command...>
retry() {
  local attempts="$1"; shift
  local delay="$1"; shift
  [[ "$1" == "--" ]] && shift
  local n=1
  until "$@"; do
    if (( n >= attempts )); then
      log_err "retry exhausted after $n attempts: $*"
      return 1
    fi
    log_warn "attempt $n failed; retrying in ${delay}s"
    sleep "$delay"
    n=$((n + 1))
  done
}

# kubectl_apply — apply a file or stdin (idempotent by nature, but logs context)
kubectl_apply() {
  local what="$1"
  if [[ -f "$what" ]]; then
    log "kubectl apply -f $what"
    kubectl apply -f "$what"
  else
    log "kubectl apply (stdin)"
    kubectl apply -f -
  fi
}

# ensure_namespace <name> [label=value ...]
ensure_namespace() {
  local ns="$1"; shift
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    log "creating namespace $ns"
    kubectl create ns "$ns"
  fi
  while (( $# > 0 )); do
    log "labelling $ns with $1"
    kubectl label ns "$ns" "$1" --overwrite
    shift
  done
}

# helm_upgrade_install <release> <chart> [extra args...]
helm_upgrade_install() {
  local release="$1"; shift
  local chart="$1"; shift
  log "helm upgrade --install $release $chart $*"
  helm upgrade --install "$release" "$chart" "$@"
}

# helm_repo_add_once <name> <url>
helm_repo_add_once() {
  local name="$1" url="$2"
  if ! helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^${name}$"; then
    helm repo add "$name" "$url"
  fi
  helm repo update "$name" >/dev/null 2>&1 || true
}

# wait_for_ready <kind> <name> <namespace> [timeout=300s]
wait_for_ready() {
  local kind="$1" name="$2" ns="$3" timeout="${4:-300s}"
  log "waiting for $kind/$name in $ns to be ready (timeout=$timeout)"
  kubectl -n "$ns" rollout status "$kind/$name" --timeout="$timeout"
}

# wait_for_pods_ready <namespace> <label-selector> [timeout=300s]
#
# Replaces `kubectl wait --for=condition=Ready -l ...` because that command
# can pin to a pod UID (e.g. the original controller that was in
# CrashLoopBackOff during a postgres race) and then watch the tombstone
# forever after the replacement pod takes over. Custom poll re-evaluates
# the selector every tick.
wait_for_pods_ready() {
  local ns="$1" selector="$2" timeout="${3:-300s}"
  local timeout_s="${timeout%s}"
  log "waiting for pods in $ns matching '$selector' (timeout=$timeout)"
  local end=$(( SECONDS + timeout_s ))
  while (( SECONDS < end )); do
    local readys
    readys=$(kubectl -n "$ns" get pods -l "$selector" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status} {end}' 2>/dev/null)
    # Need at least one pod, AND every pod must report Ready=True.
    if [[ -n "${readys// /}" ]] && ! grep -qE "False|Unknown" <<<"$readys"; then
      log_ok "  pods Ready"
      return 0
    fi
    sleep 3
  done
  log_err "  timeout waiting for pods Ready"
  return 1
}

# port_forward_bg <namespace> <kind/name> <local_port> <remote_port>
# Appends PID to $PF_PIDFILE and a URL line to $PF_URLFILE.
port_forward_bg() {
  local ns="$1" target="$2" lport="$3" rport="$4" label="${5:-$target}"
  log "port-forward $ns $target -> localhost:$lport"
  ( kubectl -n "$ns" port-forward "$target" "${lport}:${rport}" >/dev/null 2>&1 ) &
  local pid=$!
  echo "$pid" >> "$PF_PIDFILE"
  printf '%-25s http://localhost:%-5s  (ns=%s, %s, pid=%s)\n' "$label" "$lport" "$ns" "$target" "$pid" >> "$PF_URLFILE"
}

# stop_all_port_forwards — kills any PIDs we tracked and any stragglers on our ports
stop_all_port_forwards() {
  if [[ -f "$PF_PIDFILE" ]]; then
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    done < "$PF_PIDFILE"
    rm -f "$PF_PIDFILE"
  fi
  # Also kill any kubectl port-forward holding our ports (safety net for orphaned PFs from prior runs)
  for port in "$PF_GRAFANA_PORT" "$PF_PROMETHEUS_PORT" "$PF_TEMPO_PORT" "$PF_LOKI_PORT" \
              "$PF_KEYCLOAK_PORT" "$PF_AGENTREGISTRY_PORT" "$PF_KAGENT_PORT" \
              "$PF_AGENTGATEWAY_PORT" "$PF_FRONTEND_PORT" "$PF_MOCK_ATTACKER_PORT"; do
    local pids
    pids=$(lsof -ti:"$port" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086
      kill $pids 2>/dev/null || true
    fi
  done
  rm -f "$PF_URLFILE"
}

# evidence_dir <phase>  — mkdir + echo path
evidence_dir() {
  local phase="$1"
  local d="${EVIDENCE_DIR}/phase${phase}"
  mkdir -p "$d"
  echo "$d"
}

# trap helper for top-level scripts
on_error() {
  local rc=$?
  log_err "script failed with exit $rc on line ${BASH_LINENO[0]}"
  exit "$rc"
}

# ensure_host_docker_internal — only matters if you intend to browse the
# kagent UI. The chatbot demo flow uses A2A direct (SPIFFE-checked at the
# waypoint) and does NOT need this. We check non-interactively first, then
# offer to add the line via sudo if missing.
#
# Why: Docker Desktop maps host.docker.internal for traffic FROM kind pods,
# but the macOS resolver doesn't know about it natively. Without /etc/hosts
# the browser's OIDC redirect to http://host.docker.internal:5556/auth
# fails with DNS_PROBE_FINISHED_NXDOMAIN.
ensure_host_docker_internal() {
  # Already mapped? Bail.
  if grep -qE '^\s*127\.0\.0\.1\s+host\.docker\.internal' /etc/hosts 2>/dev/null; then
    log_ok "host.docker.internal already maps to 127.0.0.1 in /etc/hosts"
    return 0
  fi
  log_warn "host.docker.internal is NOT in /etc/hosts."
  log "  Needed only if you plan to BROWSE the kagent UI (OIDC flow via dex)."
  log "  The chatbot demo flow doesn't need this — it uses A2A direct."
  # Non-interactive: just warn, don't prompt (CI / unattended).
  if [[ ! -t 0 ]] || [[ "${ASSUME_YES:-}" == "1" ]]; then
    if [[ "${ASSUME_YES:-}" == "1" ]]; then
      log "  ASSUME_YES=1 — adding the entry now."
      printf '%s\n' '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts >/dev/null
      log_ok "added host.docker.internal -> 127.0.0.1"
    else
      log "  Non-interactive shell. To enable kagent UI access, run on the host:"
      log "    echo '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts"
    fi
    return 0
  fi
  read -r -p "Add it now? Requires sudo. [y/N] " ans
  case "$ans" in
    [yY]|[yY][eE][sS])
      printf '%s\n' '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts >/dev/null
      log_ok "added host.docker.internal -> 127.0.0.1"
      ;;
    *)
      log "  skipped. kagent UI OIDC login may fail with DNS_PROBE_FINISHED_NXDOMAIN."
      log "  Re-run this script (or add the line manually) when you're ready."
      ;;
  esac
}

# ensure_solo_licenses — make sure the four Solo licenses are available
# (MESH_LICENSE_KEY for Solo Istio enterprise / Solo Mesh mgmt-server,
#  AGENTGATEWAY_LICENSE_KEY, KAGENT_LICENSE_KEY, and SOLO_LICENSE_KEY as
# the catch-all single-product trial). Reads from secrets/secrets-envs.sh
# if present; prompts interactively to fill in any missing keys and writes
# the file back. Non-interactive shells skip the prompt and just check.
#
# Layout of secrets/secrets-envs.sh (gitignored):
#   export MESH_LICENSE_KEY="eyJ..."
#   export AGENTGATEWAY_LICENSE_KEY="eyJ..."
#   export KAGENT_LICENSE_KEY="eyJ..."
#   export SOLO_LICENSE_KEY="eyJ..."   # optional trial
ensure_solo_licenses() {
  local envs="$REPO_ROOT/secrets/secrets-envs.sh"
  mkdir -p "$REPO_ROOT/secrets"
  if [[ -f "$envs" ]]; then
    # shellcheck disable=SC1090
    source "$envs"
  fi

  # Which keys do we need? MESH is the critical one (MultiCluster gate).
  # AGENTGATEWAY + KAGENT are nice-to-have; the demo runs without them
  # but enterprise features (AgentgatewayPolicy CEL, AccessPolicy) need
  # them. SOLO_LICENSE_KEY is the legacy trial fallback.
  local need_prompt=0
  for v in MESH_LICENSE_KEY AGENTGATEWAY_LICENSE_KEY KAGENT_LICENSE_KEY; do
    if [[ -z "${!v:-}" ]]; then
      need_prompt=1
    fi
  done
  if (( need_prompt == 0 )); then
    log_ok "Solo licenses found in secrets/secrets-envs.sh"
    return 0
  fi

  # Non-interactive: tell the user what's missing and bail clearly.
  if [[ ! -t 0 ]] || [[ "${ASSUME_YES:-}" == "1" ]]; then
    log_err "Solo licenses missing. Required env vars (set them in secrets/secrets-envs.sh):"
    [[ -z "${MESH_LICENSE_KEY:-}"          ]] && log "    MESH_LICENSE_KEY=eyJ...        # Solo Enterprise for Istio / Solo Mesh (REQUIRED)"
    [[ -z "${AGENTGATEWAY_LICENSE_KEY:-}"  ]] && log "    AGENTGATEWAY_LICENSE_KEY=eyJ...# Solo Enterprise for agentgateway"
    [[ -z "${KAGENT_LICENSE_KEY:-}"        ]] && log "    KAGENT_LICENSE_KEY=eyJ...      # Solo Enterprise for kagent"
    die "non-interactive shell — populate secrets/secrets-envs.sh and re-run"
  fi

  log_step "Solo licenses prompt"
  log "Drop your enterprise license JWTs below (one per product). Anything you skip stays unset."
  log "These get written to $envs (gitignored)."

  prompt_license() {
    local varname="$1" label="$2"
    local existing="${!varname:-}"
    if [[ -n "$existing" ]]; then
      log_ok "  $label already set (length=${#existing})"
      return 0
    fi
    printf '  %s license JWT (paste or Enter to skip): ' "$label" >&2
    # -s would hide the input but the JWT is long enough that visible is fine
    local val=""
    read -r val || true
    if [[ -n "$val" ]]; then
      printf -v "$varname" '%s' "$val"
      export "$varname"
    fi
  }
  prompt_license MESH_LICENSE_KEY         "Solo Mesh / Solo Enterprise for Istio (REQUIRED for multi-cluster)"
  prompt_license AGENTGATEWAY_LICENSE_KEY "Solo Enterprise for agentgateway"
  prompt_license KAGENT_LICENSE_KEY       "Solo Enterprise for kagent"

  # Write back. Preserve any other vars the user already had in the file.
  {
    echo "# secrets/secrets-envs.sh — generated by scripts/00-prereqs.sh"
    echo "# Gitignored. Source automatically by the install scripts."
    for v in MESH_LICENSE_KEY AGENTGATEWAY_LICENSE_KEY KAGENT_LICENSE_KEY SOLO_LICENSE_KEY GLOO_LICENSE_KEY GLOO_MESH_LICENSE_KEY GLOO_CORE_LICENSE_KEY GLOO_MESH_GATEWAY_LICENSE_KEY GLOO_GATEWAY_LICENSE_KEY GLOO_PLATFORM_LICENSE_KEY; do
      val="${!v:-}"
      [[ -n "$val" ]] && printf 'export %s=%q\n' "$v" "$val"
    done
  } > "$envs"
  chmod 600 "$envs"
  log_ok "wrote $envs (mode 600, gitignored)"

  # Decode + validate MESH license is enterprise (not trial).
  if [[ -n "${MESH_LICENSE_KEY:-}" ]]; then
    local payload padded decoded
    payload="$(echo "$MESH_LICENSE_KEY" | awk -F. '{print $2}')"
    padded="$payload$(printf '=%.0s' $(seq 1 $((4 - ${#payload} % 4))))"
    decoded=$(echo "$padded" | base64 -d 2>/dev/null || echo "")
    if echo "$decoded" | grep -q '"product":"gloo-trial"'; then
      log_warn "MESH_LICENSE_KEY looks like a TRIAL license — MultiCluster will be DISABLED."
    elif echo "$decoded" | grep -q '"lt":"ent"'; then
      log_ok "MESH_LICENSE_KEY: enterprise (lt: ent)"
    fi
  fi
}
