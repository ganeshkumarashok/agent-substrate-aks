#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
require_owned_group

kubectl version -o json > "$ROOT/.state/kubernetes-version.json"
kubectl api-resources --api-group=certificates.k8s.io -o name \
  > "$ROOT/.state/certificate-api-resources.txt"
for resource in clustertrustbundles podcertificaterequests; do
  if ! grep -qx "$resource.certificates.k8s.io" "$ROOT/.state/certificate-api-resources.txt"; then
    progress "BLOCKED: $resource API unavailable; do not install Substrate or disable TLS"
    echo "Required API $resource is absent. See docs/rca.md; no installation attempted." >&2
    exit 1
  fi
done
kubectl get nodes -o wide > "$ROOT/.state/nodes.txt"
kubectl get storageclass > "$ROOT/.state/storageclasses.txt"
progress "PASS: both certificate APIs served; projection functionality still requires deployment verification"
