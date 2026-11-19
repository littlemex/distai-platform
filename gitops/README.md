# gitops

Everything that runs inside a cell, delivered by the EKS managed Argo CD
capability `infra/foundation` creates (hub cells only). Terraform's state
graph never contains a Kubernetes object once a cell exists (RFC
[#17](https://github.com/littlemex/distai-platform/issues/17),
[#19](https://github.com/littlemex/distai-platform/issues/19)); this
directory, delivered through Argo CD, is the only place any chart, CRD,
`NodePool` or workload is declared. The mechanism common to every add-on
and every cell is defined in RFC
[#25](https://github.com/littlemex/distai-platform/issues/25) ("the
delivery layer"); this README is the condensed, operational version of
that RFC.

## Layout

```text
gitops/
  bootstrap/
    bootstrap.sh                 # run once per cell, after terraform apply
    root-application.yaml        # template bootstrap.sh applies
  appsets/
    platform.ApplicationSet.yaml # one Application per gitops/addons/*/addon.yaml
    cells.ApplicationSet.yaml    # one Application per gitops/cells/<cell>/{capacity-pool,smoke}/*.yaml
  addons/
    <name>/addon.yaml            # one platform-wide add-on: chart, version, wave, values
  charts/
    <name>/                      # shared chart templates, parameterized per cell
  cells/
    <cluster-name>/
      capacity-pool/*.yaml        # one parameter file per NodePool
      smoke/*.yaml                 # the admin-owned smoke ClusterQueue/LocalQueue
```

Directories are named by **ownership and kind**, not by sync order: a wave
renumbering is a one-line edit inside an `addon.yaml` or cell parameter
file, never a directory move (RFC #25 Decision 3). `appsets/`, `bootstrap/`,
`addons/`, `charts/` and `cells/*/capacity-pool/`, `cells/*/smoke/` are
`CODEOWNERS`-protected to the admin.

## Bootstrapping a cell (once, after `terraform apply`)

A freshly-applied cell has a running Argo CD capability with zero
registered clusters and zero Kubernetes RBAC beyond what
`infra/foundation`'s `aws_eks_access_policy_association` grants. Run this
once per cell, and again whenever a PR adds a new chart registry (see
Versioning below):

```bash
cd infra/foundation
aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"
../../gitops/bootstrap/bootstrap.sh --tf-outputs <(terraform output -json)
```

This writes exactly three objects, all in the capability's own namespace:
a `cell-registration` `Secret` (labelled `argocd.argoproj.io/secret-type:
cluster`, `server` set to the cluster's ARN - never an API server URL),
the `platform` `AppProject`, and a root `Application` sourced at
`gitops/appsets/`. Everything after that point is Git, not a script: the
root `Application` delivers `platform.ApplicationSet.yaml` and
`cells.ApplicationSet.yaml`, which deliver every add-on and every cell's
own capacity.

The script is idempotent: re-running it with the same inputs changes
nothing. It aborts before writing anything if the live `kubectl` context's
cluster does not match `--tf-outputs`, or if a `cell-registration` Secret
already exists naming a *different* cluster - it never overwrites another
cell's registration under the same name.

## Ordering

Argo CD's own kind-ordering (CRDs before CRs) handles ordering **inside**
one `Application`. Ordering **between** the `Application`s one
`ApplicationSet` generates is `RollingSync` (ApplicationSet Progressive
Syncs, Beta since Argo CD v3.3.0); whether the managed capability exposes
it is unconfirmed as of this PR (RFC #25 Decision 4) - if it does not,
every `Application` instead syncs independently with `automated.selfHeal`,
and a later step's `Application` fails once and retries until an earlier
one it depends on converges. Either way, ordering *between*
`platform.ApplicationSet` and `cells.ApplicationSet` is always retry-based
convergence, never a `RollingSync` guarantee: `RollingSync` cannot span two
separate `ApplicationSet` objects.

| `ApplicationSet` | Step (`wave`) | Delivered in this PR |
| --- | --- | --- |
| `platform` | `crds` (`karpenter-crd`) | yes |
| `platform` | `controllers` (`karpenter`, `kueue`) | yes |
| `platform` | `accelerators` (`accel-nvidia-device-plugin`, `accel-nvidia-dra`, `accel-neuron-device-plugin`, `accel-neuron-dra`, `accel-device-classes`) | yes |
| `platform` | `extras` | no - [#18](https://github.com/littlemex/distai-platform/issues/18)/[#23](https://github.com/littlemex/distai-platform/issues/23) |
| `cells` | `capacity` (`capacity-pool/*`, `smoke/*`) | yes |
| `cells` | `teams` | no - [#22](https://github.com/littlemex/distai-platform/issues/22) |

## Versioning

Every chart is pinned to an exact version in its own `addon.yaml`
(`chart`, `repoURL`, `version`). The platform repository's own Git ref
that every `Application` is sourced from is the moving tag `stable`,
re-pointed only by `.github/workflows/move-stable-tag.yml` immediately
after a merge to `main` (never by a pull request - RFC #25 Decision 6). A
version bump needs no re-run of `bootstrap.sh`: a cell picks it up once
`stable` moves and Argo CD next polls. A PR adding a *new chart registry*
(an `addon.yaml` whose `repoURL` no existing `addon.yaml` already uses)
does need one: the `platform` `AppProject`'s `sourceRepos` is computed by
`bootstrap.sh` from this checkout's own `gitops/addons/*/addon.yaml` every
run, never hand-maintained, so the re-run is what picks up the new
registry.

A PR bumping `addons/karpenter/addon.yaml`'s version must bump
`addons/karpenter-crd/addon.yaml` to match, and vice versa: both ship the
same five Karpenter CRDs (one as plain templates, one in a `crds/` folder
skipped via `helm.skipCrds`), and a mismatched pair is exactly what the
upgrade e2e's version-pair check exists to catch.

Current pins, confirmed against each chart's own OCI manifest on
2026-11-19 (see each `addon.yaml` for the full citation and content
digest - recorded for audit, since Argo CD's `Application` CRD has no
field to pin an OCI Helm chart by digest, only by `targetRevision`
semver):

| Add-on | Chart | Version |
| --- | --- | --- |
| `karpenter-crd` | `oci://public.ecr.aws/karpenter/karpenter-crd` | `1.15.2` |
| `karpenter` | `oci://public.ecr.aws/karpenter/karpenter` | `1.15.2` |
| `kueue` | `oci://registry.k8s.io/kueue/charts/kueue` | `0.20.6` |

Accelerator add-on pins, confirmed against each chart's upstream source on
2026-11-19 ([#28](https://github.com/littlemex/distai-platform/issues/28),
Facts checked; no content digest is recorded for these yet):

| Add-on | Chart | Version |
| --- | --- | --- |
| `accel-nvidia-device-plugin` | `nvidia-device-plugin` from `https://nvidia.github.io/k8s-device-plugin` (classic Helm repository) | `0.20.2` |
| `accel-nvidia-dra` | `oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu` | `0.5.1` |
| `accel-neuron-device-plugin`, `accel-neuron-dra` | `oci://public.ecr.aws/neuron/neuron-helm-chart` (one chart, two releases with opposite toggles) | `1.11.2` |
| `accel-device-classes` | local chart `gitops/charts/accel-device-classes` | - |

## Accelerators

A `NodePool` opts its nodes into exactly one advertiser per device class by
setting a method label through `capacity-pool`'s `pool.labels`
([#19](https://github.com/littlemex/distai-platform/issues/19) Decision 2):

| Label | Value | Advertiser selected |
| --- | --- | --- |
| `distai.dev/nvidia-gpu-method` | `device-plugin` | `accel-nvidia-device-plugin` |
| `distai.dev/nvidia-gpu-method` | `dra` | `accel-nvidia-dra` |
| `distai.dev/neuron-method` | `device-plugin` | `accel-neuron-device-plugin` |
| `distai.dev/neuron-method` | `dra` | `accel-neuron-dra` |

A `NodePool` without a method label gets no advertiser, so every
advertiser is always delivered and costs nothing on a cell that does not
use it. `cells/dp-a19-gpu/capacity-pool/gpu.yaml` and
`cells/dp-a19-trn/capacity-pool/trn.yaml` are the device-plugin-method
pools the light-tier e2e launches nodes from.

## Adding a cell

1. Build the cell with `infra/foundation` and run `gitops/bootstrap/bootstrap.sh`
   against it (above). This alone delivers `karpenter-crd`, `karpenter` and
   `kueue` cluster-wide - no `NodePool` exists yet.
2. Copy `gitops/cells/example-cell/` to `gitops/cells/<cluster-name>/`,
   replacing `example-cell` with the cell's own `cluster_name` output.
3. In `capacity-pool/cpu.yaml`, keep or change `values.pool.name`; `dir`
   must stay `gitops/charts/capacity-pool`. `clusterName` and `nodeRole`
   are filled in from the Cluster generator and the registration Secret's
   own annotations - never set them by hand in this file.
4. In `smoke/queue.yaml`, set `values.clusterQueue.resourceFlavor` to the
   same `pool.name` chosen in step 3.
5. Open a PR. Once merged and `stable` moves, `cells.ApplicationSet.yaml`
   picks the new cell's files up on its own - no second `bootstrap.sh` run
   is needed for an ordinary cell addition (only a new chart registry, or
   a `--revision` change ahead of a merge, needs one).

## Known limits (this PR)

- CPU-only: `gitops/charts/capacity-pool` ships one capacity type, no
  reserved/on-demand/flex ordering across several `NodePool`s
  ([#17](https://github.com/littlemex/distai-platform/issues/17) extends
  it).
- No team object, `sharedfs` or notifications add-on ships here (RFC #25
  Decision 9); their steps exist in the RFC but have no `addon.yaml` yet,
  so they generate nothing today.
- The DRA method (`accel-nvidia-dra`, `accel-neuron-dra`) is delivered and
  statically checked, but no dynamically provisioned `NodePool` initializes
  a DRA node (#19 E2, E4c); a static `NodePool` for DRA is
  [#27](https://github.com/littlemex/distai-platform/issues/27)'s scope.
  Only the device-plugin method is verified on real nodes.
- `platform.ApplicationSet.yaml` and `cells.ApplicationSet.yaml`'s
  `goTemplate: true` plus `templatePatch` mechanism (Decision 2) is this
  PR's own construction, not a primary-sourced example from Argo CD's
  docs; it needs real-cluster verification before being relied on
  (Experiment 1).
