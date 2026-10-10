#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
if [[ "${1:-}" != "--delete-owned-resource-group" ]]; then
  echo "Destructive: deletes this lab's AKS, ACR, disks, and snapshots." >&2
  echo "Use: bash scripts/teardown.sh --delete-owned-resource-group" >&2
  exit 1
fi
require_owned_group
progress "Deleting explicitly selected owned resource group $AZURE_RESOURCE_GROUP"
az group delete --subscription "$AZURE_SUBSCRIPTION_ID" \
  --name "$AZURE_RESOURCE_GROUP" --yes
progress "Owned resource group deleted; local evidence and private GitHub repo retained"
