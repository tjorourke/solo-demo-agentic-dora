#!/usr/bin/env bash
# Shared config — namespace names, ports, image refs, chart versions.
# Source this from other scripts; do not run directly.

# Cluster + general
export CLUSTER_NAME="${CLUSTER_NAME:-trustusbank}"
export CLUSTER_KIND="${CLUSTER_KIND:-kind}"   # kind | eks
export AWS_REGION="${AWS_REGION:-eu-west-2}"
export DEMO_DOMAIN="${DEMO_DOMAIN:-trustusbank.local}"

# Namespaces (Phase 0.7 / §3 of the plan)
export NS_PLATFORM="trustusbank-platform"
export NS_MESH="istio-system"   # Istio installs to istio-system regardless of profile
export NS_OBS="trustusbank-observability"
export NS_BANK_CORE="trustusbank-bank-core"
export NS_BANK_MCP="trustusbank-bank-mcp"
export NS_BANK_AGENTS="trustusbank-bank-agents"
export NS_BANK_EVIL="trustusbank-bank-evil"
export NS_FRONTEND="trustusbank-bank-frontend"

export ALL_NAMESPACES=(
  "$NS_PLATFORM"
  "$NS_OBS"
  "$NS_BANK_CORE"
  "$NS_BANK_MCP"
  "$NS_BANK_AGENTS"
  "$NS_BANK_EVIL"
  "$NS_FRONTEND"
)

# Ambient-labelled workload namespaces (5 per Phase 0.7 verify)
export AMBIENT_NAMESPACES=(
  "$NS_BANK_CORE"
  "$NS_BANK_MCP"
  "$NS_BANK_AGENTS"
  "$NS_BANK_EVIL"
  "$NS_FRONTEND"
)

# Port-forward allocations (from 18000+, see plan §11.3)
export PF_GRAFANA_PORT=18001
export PF_PROMETHEUS_PORT=18002
export PF_TEMPO_PORT=18003
export PF_LOKI_PORT=18004
export PF_KEYCLOAK_PORT=18005
export PF_AGENTREGISTRY_PORT=18006
export PF_KAGENT_PORT=18007
export PF_AGENTGATEWAY_PORT=18008
export PF_FRONTEND_PORT=18009
export PF_MOCK_ATTACKER_PORT=18011
export PF_MAILHOG_PORT=18012
export PF_ALERTMANAGER_PORT=18013

export PF_PIDFILE="/tmp/${CLUSTER_NAME}-pf.pids"
export PF_URLFILE="/tmp/${CLUSTER_NAME}-urls.txt"

# Versions (Phase §8 pinning)
export ISTIO_PROFILE="ambient"
export GATEWAY_API_VERSION="v1.5.0"
export AGENTGATEWAY_VERSION="v1.1.0"
export KEYCLOAK_VERSION="26.0.7"
export ANTHROPIC_MODEL="claude-3-5-haiku-latest"
export LOKI_RETENTION_HOURS="61320h"   # 7 years for DORA Art. 12

# Image registry (kind: local registry; EKS: ECR)
if [[ "$CLUSTER_KIND" == "eks" ]]; then
  export DOCKER_REGISTRY="${ECR_REGISTRY:-PLACEHOLDER.dkr.ecr.${AWS_REGION}.amazonaws.com}"
else
  export DOCKER_REGISTRY="${DOCKER_REGISTRY:-localhost:5001}"
fi
export IMAGE_PREFIX="${DOCKER_REGISTRY}/trustusbank"

# MCP server images
export IMG_ACCOUNT_MCP="${IMAGE_PREFIX}/account-mcp:1.0.0"
export IMG_TRANSACTION_MCP="${IMAGE_PREFIX}/transaction-mcp:1.0.0"
export IMG_TICKET_MCP="${IMAGE_PREFIX}/ticket-mcp:1.0.0"
export IMG_EVIL_CLEAN="${IMAGE_PREFIX}/evil-tools:1.0.0"
export IMG_EVIL_RUGPULL="${IMAGE_PREFIX}/evil-tools:1.0.0-rugpull"

# Cosign keys
export COSIGN_KEY_DIR="${HOME}/.config/trustusbank/cosign"
export COSIGN_ORG_KEY="${COSIGN_KEY_DIR}/org.key"
export COSIGN_ORG_PUB="${COSIGN_KEY_DIR}/org.pub"
export COSIGN_UNTRUSTED_KEY="${COSIGN_KEY_DIR}/untrusted.key"
export COSIGN_UNTRUSTED_PUB="${COSIGN_KEY_DIR}/untrusted.pub"

# Repo paths (set by sourcing scripts via REPO_ROOT)
if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export REPO_ROOT
export MANIFESTS_DIR="${REPO_ROOT}/manifests"
export EVIDENCE_DIR="${REPO_ROOT}/evidence"
export MCP_SRC_DIR="${REPO_ROOT}/mcp-servers"
export DASHBOARDS_DIR="${REPO_ROOT}/grafana-dashboards"
