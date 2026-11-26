# jobset-crd

The JobSet `CustomResourceDefinition` (`jobsets.jobset.x-k8s.io`, group
`jobset.x-k8s.io`, served and stored version `v1alpha2`, namespaced) and
nothing else. It is the CRD-only half of the JobSet add-on
([#34](https://github.com/littlemex/distai-platform/issues/34)); the
controller and admission webhook that serve it are
[`gitops/charts/jobset`](../jobset/README.md).

| Half | Chart | Delivered by | Tier |
| --- | --- | --- | --- |
| CRD | this chart | `gitops/addons/jobset-crd/addon.yaml`, `crds` step | `core` (every cell) |
| Controller and webhook | `gitops/charts/jobset` | `gitops/addon-catalog/jobset/addon.yaml`, a cell's marker file | `platform-optional` |

## What this is

`crds/jobset.x-k8s.io_jobsets.yaml` is the upstream file from
`kubernetes-sigs/jobset` at tag `v0.13.1`, copied verbatim. Only a header
comment is added; it records the source URL, the fetch date and the
sha256 of the upstream bytes, and how to recompute it:

```bash
cd gitops/charts/jobset-crd
sed -n '/^---$/,$p' crds/jobset.x-k8s.io_jobsets.yaml | shasum -a 256
```

The same bytes are the `crds/` folder of the upstream chart
`oci://registry.k8s.io/jobset/charts/jobset:0.13.1` that
`gitops/charts/jobset` depends on, so the CRD and the controller always
come from one release.

The CRD is vendored rather than taken from the upstream chart because
upstream JobSet publishes one chart only, with no values switch that
renders the CRD alone. Depending on that chart here would also render its
controller, webhook configurations and RBAC into this core `Application`,
the same objects the `platform-optional` `jobset` `Application` owns.
`gitops/addons/jobset-crd/addon.yaml` explains the split in full.

The CRD sits in this chart's `crds/` folder, not in `templates/`: the file
is not a Helm template and is never rendered as one. Argo CD renders a
chart's `crds/` folder by default (`helm template --include-crds`) and
applies it on every sync like any other object, so an upgraded CRD file
reaches a cell on the next sync; this differs from a plain `helm install`,
which never upgrades `crds/`.

## Prerequisites

| Requirement | Why |
| --- | --- |
| Argo CD syncs this `Application` with `ServerSideApply=true` | The CRD is about 890 KB. A client-side apply stores the whole object again in the `kubectl.kubernetes.io/last-applied-configuration` annotation, whose limit is 256 KiB, and fails. `gitops/addons/jobset-crd/addon.yaml` sets this |

## Values

None. The chart has no `values.yaml` and no templates.

## Upgrading

A pull request bumping JobSet changes both halves together:

1. Replace everything from the first `---` line of
   `crds/jobset.x-k8s.io_jobsets.yaml` with the new tag's file, and update
   the tag, date and sha256 in its header.
2. Bump `gitops/charts/jobset/Chart.yaml`'s dependency version, its
   tarball digest comment and `Chart.lock`, and the image digest in
   `gitops/charts/jobset/values.yaml`.
3. Bump `appVersion` in this chart's `Chart.yaml`.

## Known issues

- `helm lint` prints `[WARNING] templates/: directory does not exist`.
  The chart has no templates by design; the warning does not fail the
  lint.
- Nothing mechanically checks that the vendored file and
  `gitops/charts/jobset`'s dependency are the same version yet; content
  review is the only control. The `karpenter-crd`/`karpenter` pair has a
  version-pair check in the upgrade e2e; this pair has none.
- Removing `gitops/addons/jobset-crd/` does not delete the CRD from a cell
  (`platform.ApplicationSet.yaml` sets `preserveResourcesOnDeletion:
  true`). Deleting the CRD by hand deletes every `JobSet` in the cluster.
