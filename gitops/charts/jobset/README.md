# jobset

A thin wrapper around the upstream
[JobSet](https://github.com/kubernetes-sigs/jobset) Helm chart (version
`0.13.1`, pinned in `Chart.yaml` with its tarball digest). It runs the
JobSet controller and its admission webhook: one `Deployment` in
`jobset-system` that reconciles `JobSet` objects (`jobset.x-k8s.io/v1alpha2`)
into ordinary `batch/v1` `Job`s, one per replicated job replica, with a
headless `Service` for stable Pod host names and a restart policy for the
whole group. It is the API a team uses to run a multi-Pod training job
([#34](https://github.com/littlemex/distai-platform/issues/34)).

This is a `tier: platform-optional` component (RFC
[#41](https://github.com/littlemex/distai-platform/issues/41) Decision 1).
Its catalog entry is `gitops/addon-catalog/jobset/addon.yaml`; a cell opts
in with a marker file, `gitops/cells/<cluster-name>/addons/jobset.yaml`,
which `gitops/appsets/addons-optional.ApplicationSet.yaml` turns into one
`Application` for that cell only. The `JobSet` CRD is not delivered by this
chart: it is the core add-on `gitops/addons/jobset-crd` (chart
[`gitops/charts/jobset-crd`](../jobset-crd/README.md)), present in every
cell, and the catalog entry sets `skipCrds: true` so the upstream chart's
own copy of the CRD is never rendered here.

The upstream chart is a Helm `dependencies:` entry pulled from an OCI
registry, so its default values sit under the `jobset:` key in this
chart's `values.yaml`, and a marker's override paths carry the same
prefix. Run `helm dependency build gitops/charts/jobset` before `helm lint`
or `helm template`; the fetched `charts/` directory is git-ignored, and
`Chart.lock` records the resolved version.

Kueue (`gitops/addons/kueue`, chart `0.20.6`) already lists
`jobset.x-k8s.io/jobset` in its default `integrations.frameworks`, so a
`JobSet` labelled `kueue.x-k8s.io/queue-name: <LocalQueue>` is suspended
on creation and admitted by Kueue as one workload. Nothing in the Kueue
add-on changes for this.

## Defaults this wrapper sets

| Value | Setting | Reason |
| --- | --- | --- |
| `jobset.fullnameOverride` | `jobset` | Stable object names (`jobset-controller`, `jobset-webhook-service`) on every cell; otherwise every name is prefixed with the per-cell `Application` name |
| `jobset.image` | `registry.k8s.io/jobset/jobset`, tag `v0.13.1` pinned by the digest of its multi-architecture image index | The upstream default is the mutable tag alone |
| `jobset.controller.tolerations` | `CriticalAddonsOnly`, `Exists` | The upstream default is none; without it the Pod has no node on a new cell (see "Placement") |
| `jobset.controller.affinity` | `karpenter.sh/nodepool` `DoesNotExist` | Keeps the Pod off every Karpenter-launched node, team pools and `optional-pool` alike; the same rule `kueue` and Karpenter's own chart use |
| `jobset.controller.resources` | the upstream `0.13.1` defaults, copied in explicitly | A reviewed diff in this repository, not a silent upstream change, moves the footprint |
| `jobset.controller.podSecurityContext`, `.securityContext`, `.hostNetwork` | the upstream `0.13.1` defaults, copied in explicitly | Non-root, `RuntimeDefault` seccomp, read-only root filesystem, all capabilities dropped, no host network: Pod Security `restricted`. Pinned so a version bump cannot loosen them without a diff |
| `jobset.certManager.enable` | `false` | No cert-manager in a cell; the controller manages its own webhook certificate, as Kueue does |
| `jobset.prometheus.enable` | `false` | No Prometheus Operator CRDs in a cell yet |
| `networkPolicy.enabled` | `true` (this wrapper's own template) | Default deny: ingress only on the webhook port `9443` and the probe port `8081`; the metrics port `8443` stays closed |

## Placement

The controller tolerates `CriticalAddonsOnly` and is kept off every
Karpenter-launched node, so it runs on the foundation's system node group,
next to Kueue. The reason is that it is an admission webhook: every
`JobSet` create and update, and every Pod a `JobSet` creates, goes through
it, the same position Kueue's own webhook has.

This is a deliberate exception to `gitops/README.md`'s Tiers rule, which
sends a platform-optional component's Pods to the core `optional-pool`
`NodePool` instead of the system node group (option (b) of RFC #41
Decision 4 Finding 1, `gitops/charts/optional-pool/README.md`). Which one
the platform keeps for an admission webhook is not decided by this chart.
Moving the controller to `optional-pool` is a change to `values.yaml`
only: replace the toleration and affinity with a `nodeSelector` on
`karpenter.sh/nodepool: optional-pool`.

## Catalog contract (RFC #41 Decision 4)

| Item | Value |
| --- | --- |
| Default namespace | `jobset-system`, the upstream chart's own documented namespace. Pod Security labels are not set on it; the controller meets `restricted` |
| Who may deploy objects into it | Only the admin-owned `Application` that `addons-optional.ApplicationSet.yaml` generates, in the `platform` `AppProject`, today |
| `dependsOn` | `jobset-crd` (core, always present) |
| Infra prerequisites | None beyond the system node group. A `JobSet` that should be admitted by Kueue needs a `LocalQueue` in its namespace |
| Overridable by a cell | `jobset.controller.resources` only (`overridableKeys` in the catalog entry) |
| Owner | `@littlemex` |

### Resource footprint

One Pod per cell, using the upstream chart's own default `resources`
(read from its `values.yaml` at version `0.13.1`; this wrapper copies them
unchanged):

| | CPU | Memory |
| --- | --- | --- |
| Requests | `500m` | `128Mi` |
| Limits | `2` | `4Gi` |

One replica, no `PodDisruptionBudget` (the upstream default). While the
Pod is down, creating or updating a `JobSet`, or creating a Pod for one,
fails, because the webhook's `failurePolicy` is the Kubernetes default
(`Fail`). Pods that are already running are unaffected.

### Security notes

- RBAC the upstream chart creates and this wrapper does not change:
  a `ClusterRole` for the controller (it manages `Job`s, `Service`s, Pods,
  `PersistentVolumeClaim`s and `JobSet`s in every namespace, reads
  `Node`s, and has `update` on every `MutatingWebhookConfiguration` and
  `ValidatingWebhookConfiguration` in the cluster to keep its own CA
  bundle current -- the upstream chart does not scope that grant by
  `resourceNames`), two namespaced `Role`s in `jobset-system`
  (leader election, and its own webhook certificate `Secret`), and two
  unbound `ClusterRole`s, `jobset-jobset-editor-role` and
  `jobset-jobset-viewer-role`, with no aggregation labels, so they add
  nothing to the built-in `edit`/`view` roles.
- A team's own identity gets `JobSet` access only through its namespaced
  `Role`: `gitops/bootstrap/team-onboard.sh` step 3 grants `jobsets` in
  the team namespace, and `gitops/bootstrap/team-rbac-guard.yaml` allows a
  team's own `Role` to grant it.
- No IAM role or Pod Identity association: the controller makes no AWS
  API call.
- The `NetworkPolicy` (`templates/networkpolicy.yaml`) allows ingress on
  ports `9443` and `8081` with no `from:` selector, because the API server
  and the kubelet cannot be matched by a selector (the same shape as
  `gitops/charts/kueue-netpol`). Every other port, including metrics on
  `8443`, is closed to every Pod.

### Removal checklist

Deleting the cell's marker file removes the `Application`, but
`addons-optional.ApplicationSet.yaml` sets
`preserveResourcesOnDeletion: true`, so the `Deployment`, `Service`s,
`NetworkPolicy`, RBAC objects, the webhook configurations and the
namespace stay in the cluster. The webhook configurations then point at a
controller that still runs; if the namespace is deleted by hand as well,
delete `jobset-mutating-webhook-configuration` and
`jobset-validating-webhook-configuration` too, or every new `JobSet` and
`JobSet` Pod is rejected. The cluster-scoped `ClusterRole`s and
`ClusterRoleBinding`s named `jobset-*` are not removed with the
namespace. The CRD stays (it is core); existing `JobSet` objects stay but
are no longer reconciled.

## Known issues

- Argo CD's repo server fetches the OCI dependency
  (`oci://registry.k8s.io/jobset/charts`) itself when it renders this
  chart. Whether the managed Argo CD capability does that for an OCI
  dependency of a Git-sourced chart without a repository credential is
  confirmed only for `dcgm-exporter`'s classic Helm repository
  dependency, not for an OCI one; real-hardware verification settles it.
- Whether `skipCrds: true` is load-bearing on the managed capability or a
  no-op is likewise left to real-hardware verification (see the catalog
  entry's comment).
- The controller's webhook certificate is generated and rotated by the
  controller itself into a `Secret` this chart renders empty, and its CA
  bundle is patched into the two webhook configurations at runtime. Argo
  CD does not render those fields, so it does not report them as drift;
  this matches how Kueue's own internal certificate behaves here.
