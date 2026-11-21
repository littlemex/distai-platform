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
covered today by this repository's single, repository-wide `.github/CODEOWNERS`
entry (`* @littlemex`) -- which also covers every other path, including
`cells/*/teams/*` once #22 ships, so nothing in `CODEOWNERS` yet
distinguishes an admin path from a team one; a path-specific rule drawing
that line is #22's own to add.

## Bootstrapping a cell (once, after `terraform apply`)

A freshly-applied cell has a running Argo CD capability with zero
registered clusters, and an access entry that carries only the two
built-in Argo-CD-capability-management policies (letting the capability
manage itself, never `AmazonEKSClusterAdminPolicy`) until
`infra/foundation`'s `aws_eks_access_policy_association` grants that too.
Run this
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
Syncs, Beta since Argo CD v3.3.0) when available; confirmed on a real
cluster (`gitops/tests/1.e2e.sh`, reading `platform.ApplicationSet`'s own
`status.applicationStatus`), the managed capability does **not** expose
it as of this PR - `status.applicationStatus` is empty, so every
`Application` instead syncs independently with `automated.selfHeal`, and
a later step's `Application` fails once and retries until an earlier one
it depends on converges. Either way, ordering *between*
`platform.ApplicationSet` and `cells.ApplicationSet` is always retry-based
convergence, never a `RollingSync` guarantee: `RollingSync` cannot span two
separate `ApplicationSet` objects.

| `ApplicationSet` | Step (`wave`) | Delivered in this PR |
| --- | --- | --- |
| `platform` | `crds` (`karpenter-crd`) | yes |
| `platform` | `controllers` (`karpenter`, `kueue`) | yes |
| `platform` | `accelerators` | no - [#19](https://github.com/littlemex/distai-platform/issues/19) |
| `platform` | `extras` | no - [#18](https://github.com/littlemex/distai-platform/issues/18)/[#23](https://github.com/littlemex/distai-platform/issues/23) |
| `cells` | `capacity` (`capacity-pool/*`, `smoke/*`) | yes |
| `cells` | `teams` | no - [#22](https://github.com/littlemex/distai-platform/issues/22) |

## Versioning

Every chart is pinned to an exact version in its own `addon.yaml`
(`chart`, `repoURL`, `version`) - a platform add-on `Application`
(`karpenter`, `karpenter-crd`, `kueue`) is sourced from its own upstream
chart registry at that pinned version, never from this platform
repository, so it is never pinned to `stable`. The platform repository's
own Git ref that the root Application and every `cells`-generated
`Application` (sourced from this repository, never an upstream registry)
are pinned to is instead the moving tag `stable`, re-pointed only by
`.github/workflows/move-stable-tag.yml` immediately after a merge to
`main` (never by a pull request - RFC #25 Decision 6). A chart version
bump needs no re-run of `bootstrap.sh`: a cell picks it up once `stable`
moves and Argo CD next polls. A PR adding a *new chart registry*
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
- No accelerator advertiser, team object, `sharedfs` or notifications
  add-on ships here (RFC #25 Decision 9); their steps exist in the RFC but
  have no `addon.yaml` yet, so they generate nothing today.
- `platform.ApplicationSet.yaml` and `cells.ApplicationSet.yaml`'s
  `goTemplate: true` plus `templatePatch` mechanism (Decision 2) is this
  PR's own construction, not a primary-sourced example from Argo CD's
  docs; Experiment 1's real-cluster verification is what this PR's own
  `gitops/tests/1.e2e.sh` now provides (every generated Application
  reaching `Synced`, `karpenter`/`kueue` also reaching `Healthy` -
  `karpenter-crd` ships only `CustomResourceDefinition` objects, with no
  `Health` status of its own; the OCI chart and the cross-generator
  `revision:` templating are both evidenced too), not an open item.
