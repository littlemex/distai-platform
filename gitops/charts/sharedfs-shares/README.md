# sharedfs-shares

Per-cell static `PersistentVolume`, reserving `PersistentVolumeClaim` and `FilesystemShare`
objects for the shared FSx for Lustre file system (#18, #22 Decision 8). Delivered by
`cells.ApplicationSet.yaml`'s own `sharedfs` wave, through a
`gitops/cells/<cluster-name>/sharedfs/*.yaml` parameter file - the same shape
`gitops/charts/capacity-pool` already uses for `cells/<cluster-name>/capacity-pool/*.yaml`,
never a catalog entry (this chart has nothing in common with `gitops/charts/sharedfs-controller`
across cells: the file system's own identity is cell-specific, the controller is not).

Requires `gitops/addon-catalog/sharedfs` already opted in for this cell (the `FilesystemShare`
CustomResourceDefinition this chart's own objects need), and `infra/foundation`'s
`var.shared_fsx_lustre` set on this cell.

## Values

| Key | Default | Meaning |
| --- | --- | --- |
| `fsx.fileSystemId` | `""` (required) | `infra/foundation` output `shared_fsx_lustre_file_system_id`. |
| `fsx.dnsName` | `""` (required) | `infra/foundation` output `shared_fsx_lustre_dns_name`. |
| `fsx.mountName` | `""` (required) | `infra/foundation` output `shared_fsx_lustre_mount_name`. |
| `fsx.storageCapacityGib` | `""` (required) | `infra/foundation` output `shared_fsx_lustre_storage_capacity_gib`. |
| `adminNamespace` | `fs-admin` | Namespace reserving the static `PersistentVolume`; never a team namespace. |

All four `fsx.*` values flow from the cell-registration Secret's own annotations through
`valuesFrom` (`gitops/bootstrap/bootstrap.sh`), never as a literal value in a committed
parameter file - see `infra/foundation/fsx.tf`'s own output descriptions for why.
`adminNamespace` is the one key above with a real default (`fs-admin`); it is never set through
a cell's own marker file today, so no `cells/<cluster-name>/sharedfs/*.yaml` parameter file in
this repository sets it.

## What this chart does

`templates/seed.yaml` runs an Argo CD `PostSync` hook Job on every sync (idempotent: `mkdir -p`
plus a `chown`/`chmod` reassert each time, never skipped just because the directories already
exist) that creates the `checkpoints` and `datasets` top-level
directories sharedfs's own `FilesystemShare` `provision` mechanism assumes already exist
("the parent must already exist, be owned by root, and not be writable by group or others" -
sharedfs's own README) - nothing else in this chart, or in sharedfs itself, creates that parent
on a brand-new, empty file system. It mounts `sharedfs-source` (the same static
`PersistentVolume` the `fs-admin` namespace's own reservation PVC binds) at its own file system
root, so it needs `fs-admin`'s own Pod Security level to allow the same `UID 0` + `CAP_CHOWN`
sharedfs's own preparer pods already run with (`baseline`, not `restricted` - see
`templates/namespace.yaml`'s own comment).

## What this chart does not do

- It does not deliver the sharedfs controller itself (`gitops/charts/sharedfs-controller`,
  `gitops/addon-catalog/sharedfs`) or publish its image
  (`gitops/bootstrap/sharedfs-image-publish.sh`) - both are prerequisites, not rendered here.
- It does not create team namespaces (`gitops/bootstrap/team-onboard.sh`'s own job) or grant
  Lustre project quotas (#18's own "Deferred to a follow-up" note).
- It seeds no data into `datasets`, only the empty directory itself (see "What this chart does"
  above): the `fs-admin` namespace's own `ReadWrite` grant on that share exists so an admin (or
  this platform's own real-machine verification) can seed actual content, not so this chart does
  it automatically.
