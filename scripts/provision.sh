#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
exec > >(tee -a "$ROOT/.state/logs/provision.log") 2>&1
trap 'progress "FAILED provisioning; line=$LINENO; inspect .state/logs/provision.log; existing resources retained"' ERR

printf '%s\n' "$AZURE_SUBSCRIPTION_ID" > "$ROOT/.state/subscription-id"
if [[ "$(az group exists --subscription "$AZURE_SUBSCRIPTION_ID" \
  --name "$AZURE_RESOURCE_GROUP")" == true ]]; then
  require_owned_group
else
  progress "Creating isolated resource group; existing clusters remain untouched"
  az group create --subscription "$AZURE_SUBSCRIPTION_ID" \
    --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" \
    --tags managedBy=agent-substrate-aks purpose=experimental-substrate \
    --output none
fi

if [[ "$(az acr list --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" --query "[?name=='$ACR_NAME'] | length(@)" -o tsv)" == 0 ]]; then
  progress "Creating Basic ACR; admin credentials disabled"
  az acr create --subscription "$AZURE_SUBSCRIPTION_ID" \
    --resource-group "$AZURE_RESOURCE_GROUP" --name "$ACR_NAME" \
    --location "$AZURE_LOCATION" --sku Basic --admin-enabled false --output none
fi

if [[ "$(az aks list --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" --query "[?name=='$AKS_CLUSTER_NAME'] | length(@)" -o tsv)" == 0 ]]; then
  progress "Creating AKS $AKS_KUBERNETES_VERSION preview; $AKS_NODE_COUNT fixed $AKS_NODE_VM_SIZE node(s); no autoscaling"
  az aks create --subscription "$AZURE_SUBSCRIPTION_ID" \
    --resource-group "$AZURE_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" \
    --location "$AZURE_LOCATION" --kubernetes-version "$AKS_KUBERNETES_VERSION" \
    --tier free --node-count "$AKS_NODE_COUNT" --node-vm-size "$AKS_NODE_VM_SIZE" \
    --nodepool-name substrate --os-sku Ubuntu2404 \
    --node-osdisk-size 64 --node-osdisk-type Managed \
    --network-plugin azure --network-plugin-mode overlay \
    --enable-managed-identity --enable-oidc-issuer --enable-workload-identity \
    --attach-acr "$ACR_NAME" --no-ssh-key --ssh-access disabled \
    --tags managedBy=agent-substrate-aks purpose=experimental-substrate \
    --output none
fi

az aks get-credentials --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" \
  --file "$KUBECONFIG" --overwrite-existing
chmod 600 "$KUBECONFIG"
az aks show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" \
  --query '{id:id,version:kubernetesVersion,state:provisioningState,nodes:agentPoolProfiles[].{name:name,count:count,vmSize:vmSize},oidcIssuer:oidcIssuerProfile.issuerUrl}' \
  -o json > "$ROOT/.state/cluster.json"
kubectl wait node --all --for=condition=Ready --timeout=5m
progress "AKS provisioned and nodes Ready; next=certificate API preflight; global kubeconfig unchanged"
bash "$ROOT/scripts/preflight.sh"
