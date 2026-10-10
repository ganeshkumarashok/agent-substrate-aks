# Agent Substrate on AKS

Reproducible, **experimental** deployment of
[Agent Substrate](https://github.com/agent-substrate/substrate) `v0.4.0` on
a dedicated AKS cluster. This is runtime infrastructure for stateful, sandboxed
agents, not an LLM or agent-development framework.

**Running and functionally verified on 2026-10-09:** three gVisor workers,
five durable suspend/resume cycles preserving both memory and filesystem
counters, restore after original worker deletion, and independent second-actor
state. This is native managed AKS, not a nested Kubernetes underlay.

## Chosen architecture

- Kubernetes `1.37.0` **AKS preview**, required for native PodCertificateRequest,
  ClusterTrustBundle, and certificate projections without modifying the managed
  control plane.
- One fixed `Standard_D4s_v5` Ubuntu 24.04 node initially; no autoscaling, GPU,
  nested virtualization, or changes to shared clusters.
- gVisor sandbox workers; Agent Gateway ingress/egress dataplane.
- Private Basic ACR with source-built images and managed-identity node pulls.
- Bundled PostgreSQL and S3-compatible RustFS on Azure Disk for an inexpensive
  lab. No assumption that upstream supports Azure Blob natively.
- ClusterIP-only application services. Access uses authenticated Kubernetes
  port-forwarding; there is no public agent endpoint.

Single-node Kubernetes, bundled development services, preview APIs, privileged
sandbox helpers, and pre-1.0 Substrate are **not production-ready**.

## Setup

Prerequisites: authenticated Azure CLI and GitHub CLI, `kubectl`, Docker, Git,
GNU Make, and Go with automatic toolchain downloads enabled. The pinned upstream
requires Go `1.27.0`; do not rewrite its dependency versions.

```bash
# Once per new checkout; keep an existing .env unchanged.
cp -n .env.example .env
# Edit .env: select your resource group, AKS name and unique registry name.
# Review the non-sensitive defaults in config/deployment.env.
# AZURE_SUBSCRIPTION_ID may be set before the first provisioning run.
bash scripts/build-tools.sh
bash scripts/provision.sh
bash scripts/build-images.sh
bash scripts/install.sh
bash scripts/verify.sh
```

All cluster credentials, registry credentials, build caches, logs, and progress
receipts remain under ignored `.state/` and `.cache/`. The scripts never modify
the default kubeconfig or default Docker credential store. Once provisioned,
the Azure subscription is pinned in `.state/subscription-id`.
Actual deployment names belong in ignored `.env` or environment variables,
not public configuration. The public evidence uses stable aliases for actor,
worker, node, and IP identifiers; raw receipts remain local in `.state/`.

See [the compatibility investigation](docs/rca.md) for root causes and evidence.
The [setup/operations runbook](docs/runbook.md) covers exact inventory, access,
verification, cost, lifetime, diagnostics, and teardown.
The [recorded functional evidence](docs/evidence/verification-2026-10-09.json)
contains the measured counters, worker transitions, health, and cleanup results.

The installer reuses upstream's `--kind` **local-service manifest profile** on
the actual managed AKS cluster; it does not run Kind or a second Kubernetes
control plane. The checked-in adapter replaces development storage passwords
with a generated Kubernetes Secret and mounts the AKS node's own ACR credential
provider read-only so actor image pulls use its managed identity.

The pinned upstream Go compiler may report a dirty VCS state after this
manifest-only adapter is applied. No upstream Go source is changed, and the
Substrate version is explicitly stamped `v0.4.0`.

## Access and operations

```bash
bash scripts/port-forward.sh
# In another terminal, source scripts/common.sh before using kubectl ate.
# Actor-routing requests go to http://127.0.0.1:18080.
```

Storage keys are generated once and never committed or printed. The lab's
kubeconfig uses certificate authentication and is stored mode 0600; production
should use Entra-backed operator access and disable local accounts. Egress
credential injection is deliberately off because this test needs no model
credentials.

Cloud resources continue to incur charges after this CLI exits. One D4s_v5
node, its OS/data disks, a Basic ACR, and standard outbound networking are the
bounded footprint; Free AKS tier removes the control-plane fee, not compute
charges. Public retail compute is about **USD 5.21/day**, plus other resources.
Subscription retention policies may automatically remove lab resources; check
your resource group's tags locally. This setup does not override them. Stop
the lab cluster when idle or remove only its owned resource group:

```bash
source scripts/common.sh
az aks stop --subscription "$AZURE_SUBSCRIPTION_ID" \
  -g "$AZURE_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME"
# Destructive removal of this lab, including snapshots:
bash scripts/teardown.sh --delete-owned-resource-group
```

## Repository status

Public repository: <https://github.com/ganeshkumarashok/agent-substrate-aks>.
The setup, runbook, compatibility investigation, and anonymized verification
evidence are versioned here. Deployment-specific settings, credentials, build
caches, and raw operational receipts remain local and are excluded from Git.
