#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
exec > >(tee -a "$ROOT/.state/logs/build-images.log") 2>&1
trap 'progress "FAILED image build; line=$LINENO; inspect .state/logs/build-images.log"' ERR
require_owned_group
az acr login --subscription "$AZURE_SUBSCRIPTION_ID" --name "$ACR_NAME"
ACR_SERVER="$(az acr show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)"
progress "Building 7 amd64 images from $SUBSTRATE_COMMIT into private ACR; no upstream code changes"
cd "$UPSTREAM"
make VERSION="$SUBSTRATE_VERSION" KO_DOCKER_REPO="$ACR_SERVER/substrate" \
  KO_DEFAULTPLATFORMS=linux/amd64 KO_TAGS="--tags=$SUBSTRATE_VERSION" \
  IMAGES="./cmd/ateapi ./cmd/atecontroller ./cmd/atelet ./cmd/atenet ./cmd/podcertcontroller ./cmd/ateom-gvisor" \
  DEMOS="./demos/counter" build-images build-demos
az acr repository list --subscription "$AZURE_SUBSCRIPTION_ID" --name "$ACR_NAME" \
  -o json > "$ROOT/.state/image-repositories.json"
progress "7 source images published; installer will resolve tags to immutable digests"
