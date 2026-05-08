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
  local labels=("$@")
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    log "creating namespace $ns"
    kubectl create ns "$ns"
  fi
  for lbl in "${labels[@]}"; do
    log "labelling $ns with $lbl"
    kubectl label ns "$ns" "$lbl" --overwrite
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
wait_for_pods_ready() {
  local ns="$1" selector="$2" timeout="${3:-300s}"
  log "waiting for pods in $ns matching '$selector' (timeout=$timeout)"
  kubectl -n "$ns" wait --for=condition=Ready pods -l "$selector" --timeout="$timeout"
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
              "$PF_AGENTGATEWAY_PORT" "$PF_FRONTEND_PORT" "$PF_DIGEST_WATCHER_PORT"; do
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
