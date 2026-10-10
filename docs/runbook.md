# Setup and operations

## Inventory

| Resource | Selection |
| --- | --- |
| Region | `centralus` |
| Resource group | Selected locally with `AZURE_RESOURCE_GROUP` |
| AKS | Selected locally with `AKS_CLUSTER_NAME`; Kubernetes `1.37.0` preview, Free tier |
| Node pool | `substrate`, one `Standard_D4s_v5`, Ubuntu 24.04, 64 GiB managed OS disk |
| Registry | Selected locally with `ACR_NAME`; Basic, admin access disabled |
| Substrate | `v0.4.0`, `756c2a53741121e728f4cc3066c8a19e575b4919` |
| Sandboxes | Three gVisor workers on the fixed node; no microVM/KVM dependency |
| Dataplane | Upstream's pinned Agent Gateway image, credential injection disabled |
| Durable stores | PostgreSQL and RustFS, each with a Bound 1 GiB Azure Disk PVC |
| Telemetry | OpenTelemetry collector, Prometheus, Jaeger in `otel-system` |
| Application exposure | ClusterIP only; loopback-bound authenticated Kubernetes port-forward |

The Kubernetes API endpoint is public and certificate-authenticated; this is
not a private-cluster or production identity deployment.

## Reproduction

Review the non-sensitive defaults in `config/deployment.env` before creating
billable resources. Copy `.env.example` to ignored `.env` and choose your own
resource group, cluster, and globally unique registry name. These settings may
also be exported as environment variables; local `.env` values take precedence.
Do not overwrite an existing `.env`. `AZURE_SUBSCRIPTION_ID` may be provided
explicitly before the first run; subsequent runs reuse the locally recorded
subscription rather than whichever account happens to be current.

```bash
cd agent-substrate-aks
cp -n .env.example .env
# Edit .env, including its required ACR_NAME, before continuing.
bash scripts/build-tools.sh
bash scripts/provision.sh
bash scripts/build-images.sh
bash scripts/install.sh
bash scripts/verify.sh
```

The first command obtains the pinned upstream checkout, uses Go's automatic
toolchain resolution, builds the installer and CLI, and installs a
checksum-verified, task-local kubectl matching the server.

Provisioning creates only this dedicated resource group, Basic ACR and AKS.
Existing resources are accepted only inside a group marked
`managedBy=agent-substrate-aks`. The script does not upgrade or resize existing
clusters merely because config was edited.

Builds target `linux/amd64` even from an ARM64 development host. Seven images
are published with the release tag and resolved to immutable digests by the
installer. It does not pull the inaccessible example release repository.

The manifest adapter is applied idempotently only to the ignored upstream
checkout. It preserves mTLS, configures the implemented S3 backend, generates
storage credentials in a Kubernetes Secret, and reuses the node's managed
identity through its own credential provider. It changes no upstream Go code.
The `--kind` flag selects a local-services profile, not a Kind cluster.

Verification performs real HTTP actor requests, checks exact memory and file
counts, runs five durable suspend/resume cycles, deletes the first suspended
actor's worker, and confirms restore onto another worker. A simultaneously
running second actor must start at `1/1` on a different worker. Both proof actors
end suspended; the local port-forward is stopped even on failure.

The test covers process and filesystem state across **worker pods on one
node**, not cross-node CPU portability. It makes no LLM calls, requires no model
API key, and is not a throughput or production-capacity benchmark.

## Interact with a retained actor

```bash
source scripts/common.sh
kubectl ate get actor-templates -a ate-demo-counter
kubectl ate get actors -a ate-demo-counter
bash scripts/port-forward.sh
```

In another terminal from the repository:

```bash
source scripts/common.sh
actor="$(python3 -c 'import json; print(json.load(open(".state/verification.json"))["actor"])')"
curl --fail --show-error -X POST \
  -H "ate-target-actor: ate-demo-counter/$actor" http://127.0.0.1:18080/
kubectl ate suspend actor "$actor" -a ate-demo-counter
```

Immediately after the recorded verification, this request should advance both
counters from `6` to `7`; further requests continue incrementing them. Stop the
foreground port-forward with Ctrl-C.

## Diagnostics

```bash
source scripts/common.sh
kubectl get pods -A
kubectl get clustertrustbundles
kubectl get podcertificaterequests -A
kubectl -n ate-system get pvc
kubectl -n ate-system logs daemonset/atelet-v0-4-0 --tail=100
kubectl -n podcertificate-controller-system logs deploy/podcertificate-controller --tail=100
kubectl ate get actor-templates -a ate-demo-counter -o json
kubectl ate get actors -a ate-demo-counter -o json
```

Read `.state/progress.log` for phase transitions and `.state/logs/` for complete
command output. `.state/verification.json` records the latest exact results;
previous runs remain in `.state/verification-history/`.
The [delivery evidence](evidence/verification-2026-10-09.json) preserves the
final run's measurements and worker relationships using stable aliases for
deployment-specific actor, worker, node, and IP identifiers. Unmodified receipts
remain local in `.state/`; neither contains published kubeconfig or registry
credentials.
Successful installer records remain in `.state/installer-records/installs/`;
upstream also retains failed install records. Do not commit kubeconfigs, Docker
tokens, Kubernetes Secrets, or raw credential data.

During bootstrap, transient `FailedMount` events can occur while pod
certificates are issued or router config arrives. They were resolved in this
run; persistent failures require certificate controller logs, issuance
conditions, and current Pod readiness, not just old warning events.

## Cost, lifetime, and cleanup

Azure's public retail price returned **USD 0.217/hour** for regular Linux
`Standard_D4s_v5` in Central US on 2026-10-09: **USD 5.208/day for compute**
if left running continuously, before disks, Basic ACR, public IP/outbound
networking, taxes, or negotiated discounts. This is not an account billing
quote. Free AKS tier removes the control-plane fee, not worker charges.

Source:
[Azure Retail Prices API](https://prices.azure.com/api/retail/prices?$filter=armRegionName%20eq%20%27centralus%27%20and%20armSkuName%20eq%20%27Standard_D4s_v5%27%20and%20priceType%20eq%20%27Consumption%27).

Subscription retention policies may automatically remove a lab. Inspect your
resource group's tags locally rather than publishing deployment-specific
retention metadata:

```bash
source scripts/common.sh
az group show --subscription "$AZURE_SUBSCRIPTION_ID" \
  -n "$AZURE_RESOURCE_GROUP" --query tags -o json
```

Treat the lab as short-lived. Retention tags declare intended cleanup, not proof
that a future garbage collector executed. The setup does **not** remove or
extend your subscription's retention tags. Recreate the lab from these scripts
after cleanup, or obtain authorization before changing retention.

Stop compute when idle, retaining disks and registry:

```bash
source scripts/common.sh
az aks stop --subscription "$AZURE_SUBSCRIPTION_ID" \
  -g "$AZURE_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME"
az aks start --subscription "$AZURE_SUBSCRIPTION_ID" \
  -g "$AZURE_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME"
```

Stop does not remove all charges or override subscription cleanup. To explicitly
delete this lab, including its durable snapshots:

```bash
bash scripts/teardown.sh --delete-owned-resource-group
```

The teardown verifies the ownership marker and targets this exact group. It
does not delete local evidence, the GitHub repository, or other groups.
Do not run it until snapshot loss is intended.

## Production gaps

The current result is a validated lab, not a production blueprint. Production
requires a supported non-preview AKS release exposing these APIs, Entra-backed
operator access, appropriate network policy/private endpoints, HA control-plane
services and databases, backup/restore and key rotation, durable object-storage
capacity, controlled upgrades, tenant authorization review, multi-node CPU
compatibility validation, and production telemetry.

The CLI session monitor is stopped after verified delivery. It is not a
permanent health service and cannot survive CLI shutdown or laptop sleep.
