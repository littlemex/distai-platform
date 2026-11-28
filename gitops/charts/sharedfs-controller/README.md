# sharedfs-controller

Delivers [littlemex/sharedfs](https://github.com/littlemex/sharedfs)'s controller, CRDs, RBAC
and admission-policy guard (#18): the component that turns one shared FSx for Lustre file
system (`infra/foundation`'s `var.shared_fsx_lustre`) into per-team directories tenants claim
with ordinary PersistentVolumeClaims. See `templates/crds.yaml`'s own header for the pinned
upstream commit and the exact, small set of edits from its literal Kustomize render (this
project ships no Helm chart of its own).

This chart delivers the controller only. The static PersistentVolume, its reserving PVC and the
`FilesystemShare` objects (`checkpoints`, `datasets`) are `gitops/charts/sharedfs-shares`, a
separate, per-cell chart - this one has nothing cell-specific in it beyond the image.

## Values

| Key | Default | Meaning |
| --- | --- | --- |
| `image` | `""` (required) | Full `repository@sha256:...` reference to the self-published controller image. No safe default exists: see this file's own `values.yaml` comment. Set per cell through `gitops/addon-catalog/sharedfs/addon.yaml`'s own cell marker, via `valuesFrom` reading `distai.dev.annotations/sharedfs-controller-image` - never a literal in a committed file. |
| `replicaCount` | `2` | Matches upstream's own default (two replicas, leader election, a standby takes over the lease). |
| `networkPolicy.allowedPeers` | `[]` | `NetworkPolicyPeer` entries allowed to reach the controller's own metrics port (8443). Empty denies every peer (RFC #25's "default deny, name the exception" - the same convention `dcgm-exporter`'s own `networkPolicy.allowedPeers` already uses). |

## Known limits (this PR)

- **No Lustre project quotas.** Upstream's `config/quota` (the `sharedfs-quota` namespace, its
  own `Dockerfile.quota` image and the controller's `--quota-namespace`/`--quota-image` flags)
  is not delivered by this chart: none of the three pieces is wired up. `infra/foundation/fsx.tf`
  already pins Lustre `2.15` for every deployment type, so that half of the original gap is
  closed, but all three pieces above are still open - the namespace and the two flags are small
  additions once the quota-pod image exists, but this PR's own
  `gitops/bootstrap/sharedfs-image-publish.sh` does not build that image at all, so none of the
  three is wired up in practice. Tracked as #18's own "Deferred to a follow-up" note.
- **`--preparer-image` is always set to the controller's own image** (this chart's one addition
  to upstream's literal Deployment args - see `templates/crds.yaml`'s header, point 4):
  `gitops/charts/sharedfs-shares`' own `checkpoints` `FilesystemShare` sets `provision` (`datasets`
  does not - see that chart's own `templates/filesystemshares.yaml`), and upstream's controller
  refuses to start at all once any share does, unless this flag is set.
