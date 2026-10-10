# AKS compatibility investigation

Investigation started 2026-10-09. Upstream is Apache-2.0-licensed
`agent-substrate/substrate`, pinned to release `v0.4.0`,
commit `756c2a53741121e728f4cc3066c8a19e575b4919`.

There was no supplied failing deployment or incident ID. This is a deployment
compatibility RCA, not a claim to have diagnosed an existing customer incident.

## Certificate API dependency

Upstream mounts `podCertificate` and `clusterTrustBundle` projected volumes and
runs its own certificate signer. The Kind quickstart explicitly enables
ClusterTrustBundle, ClusterTrustBundleProjection, and PodCertificateRequest.
These features are off by default through Kubernetes 1.36.

On managed control planes that omit the APIs, installation can look successful
while projections are stripped or empty and components fail on missing
`credential-bundle.pem` or `trust-bundle.pem`. Changing JWT authentication does
not eliminate the TLS dependency.

Public corroboration:
[kagent issue 3071](https://github.com/kagent-dev/kagent/issues/3071).
Upstream evidence: `hack/create-kind-cluster.sh`,
`manifests/ate-install/atelet.yaml`, and
`cmd/ate-setup/internal/steps/prereqs.go`.

**Selected resolution:** isolated native AKS 1.37.0 preview, followed by live
API discovery and functional certificate projection validation. An API presence
check alone is not proof that certificates or the runtime work. If AKS omits
the features, fail before installation rather than disabling TLS or pretending
a second Kubernetes cluster inside AKS is ordinary managed AKS support.

## Release distribution

`docker manifest inspect ghcr.io/agent-substrate/substrate/ateapi:v0.4.0`
returned `denied` with the current credentials. The example image repository in
upstream operator documentation is not an accessible release distribution for
this run. The release has no binary assets.

**Selected resolution:** build the pinned public source into a dedicated private
ACR, not arbitrary third-party images. Agent Gateway avoids an unnecessary
cross-architecture Envoy/Rust build on the ARM64 development host.

## Platform-specific adaptations to validate

The upstream Kind profile supplies local PostgreSQL, RustFS and telemetry, but
its defaults assume localhost image registries and disable node credential
provider mounts. AKS private ACR actor-image pulls must be wired explicitly.
The default GCP profile is also unsuitable: its snapshot paths and credential
provider host paths are GCP-specific.

Do not infer Azure Blob support from generic cloud-neutral architecture claims.
This lab uses the implemented S3 storage backend with persistent RustFS.

Full-state gVisor snapshots include CPU-dependent state. A single fixed node
avoids migration across heterogeneous CPU generations. Multi-node expansion
requires explicit CPU compatibility checks and a separate cross-node restore
test.

## Verified status

GitHub repository created. Pinned source and automatic Go 1.27.0
toolchain verified. Native AKS `1.37.0` preview provisioned successfully with one
Ready D4s_v5 node. Live discovery serves ClusterTrustBundle and
PodCertificateRequest as `certificates.k8s.io/v1`.

Node inspection verified:

```text
/var/lib/kubelet/credential-provider-config.yaml
/var/lib/kubelet/credential-provider/acr-credential-provider
/etc/kubernetes/azure.json
```

The adapter passes a canonical reverse `git apply --check` and complete
Kind-Agentgateway Kustomize render. Node diagnostic pod removed. A
checksum-verified task-local kubectl 1.37.0 fixes the existing global client's
unsupported 1.34-to-1.37 version skew without changing global tooling.

The first hand-authored adapter diff did not apply; it was corrected against
the pinned source and regenerated as a canonical Git diff.

## Outcome

**Native AKS installation succeeded.** The pod certificate signer published
its trust bundles and all core components started with their projected
certificates. Fourteen live PodCertificateRequests were observed issued;
there was no insecure transport bypass.

The AKS node's `acr-credential-provider` loaded successfully, resolved managed
identity credentials for the private counter image, and atelet pulled its
digest into the layer cache. This proves actor image authentication in addition
to ordinary Kubernetes worker-image pulls.

All three gVisor workers and the counter golden snapshot became ready. Real
routed HTTP requests preserved memory and file counters from `1/1` through
`6/6` across **five durable suspend/resume cycles**. The original worker pod was
deleted after the first durable suspend; the actor resumed on other worker pods
without state loss. A concurrently active second actor started at `1/1` on a
different worker, demonstrating independent actor state.

Both proof actors were left suspended, all worker capacity was freed, and the
temporary port-forward and diagnostic pod were removed. PostgreSQL and RustFS
PVCs are Bound; the OpenTelemetry collector, Prometheus, and Jaeger are ready.
No global kubeconfig, Docker credential store, shared cluster, or global
kubectl binary was modified.

**Limits:** one physical node, gVisor only, no paid model calls, no cross-node
restore or scale benchmark, pre-1.0 Substrate, and AKS preview. The result does
not justify claims of production readiness or advertised north-star scale.

See [the runbook](runbook.md) for the exact setup and the subscription's
short-lived resource-group retention policies. The
[final verification receipt](evidence/verification-2026-10-09.json) records the
exact counters, worker changes, health, and restoration result, with stable
aliases replacing deployment-specific identifiers. Superseded test
actors were deleted after their evidence was preserved; the latest proof pair
remains suspended.
