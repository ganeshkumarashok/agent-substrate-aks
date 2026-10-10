#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config/deployment.env"
if [[ -f "$ROOT/.env" ]]; then
  source "$ROOT/.env"
fi
: "${AZURE_RESOURCE_GROUP:?Set AZURE_RESOURCE_GROUP in .env or the environment; see .env.example}"
: "${AKS_CLUSTER_NAME:?Set AKS_CLUSTER_NAME in .env or the environment; see .env.example}"
: "${ACR_NAME:?Set a unique ACR_NAME in .env or the environment; see .env.example}"
umask 077
mkdir -p "$ROOT/.state/logs" "$ROOT/.cache/bin" "$ROOT/.state/docker"
export KUBECONFIG="$ROOT/.state/kubeconfig"
export DOCKER_CONFIG="$ROOT/.state/docker"
export PATH="$ROOT/.cache/bin:$PATH"
export NO_DEV_ENV=1
UPSTREAM="$ROOT/.cache/upstream"
if [[ -f "$ROOT/.state/subscription-id" ]]; then
  AZURE_SUBSCRIPTION_ID="$(cat "$ROOT/.state/subscription-id")"
else
  AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
fi

progress() {
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" \
    | tee -a "$ROOT/.state/progress.log"
}

require_owned_group() {
  local marker
  marker="$(az group show --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name "$AZURE_RESOURCE_GROUP" --query tags.managedBy -o tsv)"
  if [[ "$marker" != agent-substrate-aks ]]; then
    echo "Refusing to modify a resource group not owned by this deployment." >&2
    return 1
  fi
}
