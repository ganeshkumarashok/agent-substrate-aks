#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
exec > >(tee -a "$ROOT/.state/logs/install.log") 2>&1
trap 'progress "FAILED installation; line=$LINENO; inspect .state/logs/install.log; cluster retained for diagnosis"' ERR

bash "$ROOT/scripts/preflight.sh"
if [[ ! -f "$ROOT/.state/image-repositories.json" ]]; then
  echo "Run scripts/build-images.sh successfully before installation." >&2
  exit 1
fi
if git -C "$UPSTREAM" apply --reverse --check "$ROOT/patches/aks-local-profile.patch" 2>/dev/null; then
  progress "AKS manifest adapter already applied"
else
  git -C "$UPSTREAM" apply --check "$ROOT/patches/aks-local-profile.patch"
  git -C "$UPSTREAM" apply "$ROOT/patches/aks-local-profile.patch"
fi

kubectl create namespace ate-system --dry-run=client -o yaml | kubectl apply -f -
existing="$(kubectl -n ate-system get secret substrate-s3 --ignore-not-found -o name)"
if [[ -z "$existing" ]]; then
  python3 - <<'PY' | kubectl apply -f -
import json
import secrets
print(json.dumps({
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "substrate-s3", "namespace": "ate-system"},
    "type": "Opaque",
    "stringData": {
        "access-key": secrets.token_hex(16),
        "secret-key": secrets.token_urlsafe(48),
    },
}))
PY
fi
ACR_SERVER="$(az acr show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)"
az acr login --subscription "$AZURE_SUBSCRIPTION_ID" --name "$ACR_NAME"
export EXPECTED_JWT_ISSUER
EXPECTED_JWT_ISSUER="$(az aks show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" \
  --query oidcIssuerProfile.issuerUrl -o tsv)"

setup() {
  "$ROOT/.cache/bin/ate-setup" --kind --context "$AKS_CLUSTER_NAME" \
    --kubeconfig "$KUBECONFIG" --no-dev-env --no-report-defaults \
    --ko-default-platforms linux/amd64 --ko-docker-repo "$ACR_SERVER/substrate" \
    --image-repo "$ACR_SERVER/substrate" --image-tag "$SUBSTRATE_VERSION" \
    --record-dir "$ROOT/.state/installer-records" \
    --rollout-timeout 10m --atenet-dataplane agentgateway \
    --credential-provider '{"enabled":false}' "$@"
}
cd "$UPSTREAM"
progress "Installing Substrate control plane; local-service profile on native AKS, not a nested Kind cluster"
setup deploy ate-system
kubectl -n ate-system rollout status deployment/rustfs --timeout=5m
kubectl -n ate-system wait job/rustfs-bucket-init --for=condition=complete --timeout=5m
progress "Control plane and snapshot bucket ready; deploying three gVisor workers and counter golden snapshot"
setup deploy demo counter
kubectl get clustertrustbundles > "$ROOT/.state/trust-bundles.txt"
kubectl -n ate-demo-counter get workerpool,pods -o wide > "$ROOT/.state/workerpool.txt"
progress "Substrate and counter template installed; next=state-preserving functional verification"
