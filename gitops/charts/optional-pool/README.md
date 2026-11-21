# optional-pool

One admin-owned Karpenter `NodePool` and its `EC2NodeClass`: untainted,
on-demand, CPU only, created in every cell. It is where the pods of
platform-optional components (RFC
[#41](https://github.com/littlemex/distai-platform/issues/41) Decision 1)
run. Without it, such a pod has no node to land on: the foundation's
system node group is tainted `CriticalAddonsOnly=true:NoSchedule` and
reserved for `kube-system` and the Karpenter/Kueue controllers, and a
team's own `capacity-pool` `NodePool` is team capacity that may not exist
in a given cell at all.

`gitops/addons/optional-pool/addon.yaml` delivers this chart through
`platform.ApplicationSet.yaml` in the `controllers` step, as `tier: core`,
so every cell has the pool whether or not it opts into any
platform-optional component. With no pod scheduled on it, Karpenter
launches no node for it and the pool costs nothing.

## Open decision: whether this pool exists

`enabled` (default `true`) switches between the two options RFC #41
Decision 4 Finding 1 lists. The choice is not yet confirmed by the
maintainer.

| `enabled` | Option | Pros | Cons |
| --- | --- | --- | --- |
| `true` | (b) a dedicated, untainted CPU pool in every cell (this chart) | Keeps the system node group for `kube-system` and the Karpenter/Kueue controllers only, the principle `distributed-ai`'s `observability.tf` states; the total footprint of admin add-ons is bounded by one reviewable `limits` value | One more object every cell carries, even one with no platform-optional component (no node, so no cost, until a pod needs one) |
| `false` | (a) no dedicated pool; each platform-optional component tolerates `CriticalAddonsOnly` and runs on the system node group | Nothing new to provision | The system node group is sized for the critical boot path, not for a growing set of admin add-ons whose combined footprint nothing bounds |

With `enabled: false` the chart renders no object at all.

## Values

| Key | Required | Description |
| --- | --- | --- |
| `clusterName` | yes | Matches the `karpenter.sh/discovery` tag the foundation layer puts on the cell's subnets and security group |
| `nodeRole` | yes | IAM role name for nodes launched by Karpenter (`infra/foundation` output `karpenter_node_role_name`) |
| `enabled` | no | `true` renders the pool, `false` renders nothing (see above); defaults to `true` |
| `pool.name` | no | Name shared by the `NodePool` and its `EC2NodeClass`; defaults to `optional`. Must not equal any `capacity-pool` `pool.name` in the same cell |
| `pool.limits` | no | Karpenter `NodePool` resource limits; defaults to `cpu: "8"`, deliberately small, since this pool is for admin component pods only, never team work |
| `pool.disruption` | no | Karpenter `NodePool` disruption settings |
| `requirements` | no | Karpenter `NodePool` scheduling requirements; defaults to on-demand, amd64, `c`/`m`/`r` instance categories, generation above 5 |
| `amiFamily`, `amiSelectorTerms` | no | `EC2NodeClass` AMI selection; defaults to the same pinned AL2023 alias as `gitops/charts/capacity-pool` (`al2023@v20261112`), bumped only by a reviewed diff |

`clusterName` and `nodeRole` are set by `valuesFrom` in
`gitops/addons/optional-pool/addon.yaml` (the Cluster generator's own
`name` and the registration Secret's
`distai.dev.annotations/karpenter-node-role` annotation), never by hand.

## Known limits

- No Kueue `ResourceFlavor` points at this pool, by design: it is not
  capacity Kueue admits team work onto.
- Untainted means any pod with no `nodeSelector` can be scheduled here,
  including a team's pod that matches no other pool. `pool.limits` caps the
  total; admission rules that keep team pods off this pool belong to
  [#22](https://github.com/littlemex/distai-platform/issues/22).
- `EC2NodeClass.spec.role` and the subnet/security-group discovery tags
  assume the foundation layer (`infra/foundation`) created this cell.
