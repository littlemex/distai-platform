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

All four `fsx.*` values and `adminNamespace` flow from the cell-registration Secret's own
annotations through `valuesFrom` (`gitops/bootstrap/bootstrap.sh`), never as a literal value in
a committed parameter file - see `infra/foundation/fsx.tf`'s own output descriptions for why.

## What this chart does not do

- It does not deliver the sharedfs controller itself (`gitops/charts/sharedfs-controller`,
  `gitops/addon-catalog/sharedfs`) or publish its image
  (`gitops/bootstrap/sharedfs-image-publish.sh`) - both are prerequisites, not rendered here.
- It does not create team namespaces (`gitops/bootstrap/team-onboard.sh`'s own job) or grant
  Lustre project quotas (#18's own "Deferred to a follow-up" note).
- It seeds no data into `datasets`: the `fs-admin` namespace's own `ReadWrite` grant on that
  share exists so an admin (or this platform's own real-machine verification) can, not so this
  chart does it automatically.
