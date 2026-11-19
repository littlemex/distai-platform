# capacity-pool

One Karpenter `NodePool`, its `EC2NodeClass` and the matching Kueue
`ResourceFlavor`, as a single release. The `ResourceFlavor` matches nodes by
the `karpenter.sh/nodepool` label Karpenter sets on every node it launches.
Each release declares exactly one capacity type, so the `-rsv`, `-od` and
`-flex` pools of [#17](https://github.com/littlemex/distai-platform/issues/17)
are three releases of this chart:

| `pool.capacityType` | `karpenter.sh/capacity-type` requirement | `EC2NodeClass.spec.capacityReservationSelectorTerms` |
| --- | --- | --- |
| `on-demand` (default) | `["on-demand"]` | not rendered |
| `reserved` | `["reserved"]` | `[{tags: reservation.tags, instanceMatchCriteria: reservation.instanceMatchCriteria}]` |
| `flex` | `["spot", "on-demand"]` | not rendered |

`reserved` never falls back to on-demand within the same `NodePool`: a pool
mixing reserved and on-demand capacity would let Karpenter launch on-demand
nodes while Kueue's quota on the flavor still describes the reservation.

## Values

| Key | Required | Default | Description |
| --- | --- | --- | --- |
| `clusterName` | yes | `""` | Matches the `karpenter.sh/discovery` tag the foundation layer puts on the cell's subnets and security group |
| `nodeRole` | yes | `""` | IAM role name for nodes launched by Karpenter (`infra/foundation` output `karpenter_node_role_name`) |
| `pool.name` | yes | `""` | Name shared by the `NodePool`, its `EC2NodeClass` and the `ResourceFlavor` |
| `pool.capacityType` | yes | `on-demand` | One of `on-demand`, `reserved`, `flex` (table above); any other value fails the render. The chart generates the `karpenter.sh/capacity-type` requirement from it |
| `pool.requirements` | no | amd64, `c`/`m`/`r` instance categories, generation > 5 | Every other Karpenter `NodePool` requirement, rendered after the generated capacity-type entry. An entry with key `karpenter.sh/capacity-type` fails the render |
| `pool.limits` | no | `cpu: "32"` | Karpenter `NodePool` resource limits (see Quotas below) |
| `pool.disruption` | no | `WhenEmptyOrUnderutilized`, `60s` | Karpenter `NodePool` disruption settings |
| `reservation.tags` | when `reserved` | `{}` | Tags selecting the Capacity Reservation(s) or Capacity Block(s) backing a `reserved` pool. Must be non-empty, with no empty key or value, when `pool.capacityType` is `reserved`; ignored otherwise |
| `reservation.instanceMatchCriteria` | no | `targeted` | `targeted` or `open`; any other value fails the render. Used only when `pool.capacityType` is `reserved` |
| `accelerator.resourceName` | no | `""` | When set, rendered as the annotation `distai.dev/accelerator-resource-name` on the `NodePool` and the `ResourceFlavor` (for example `nvidia.com/gpu`, `aws.amazon.com/neuron`). Provenance only: no template branches on its value |
| `accelerator.taint.key`, `.value`, `.effect` | no | `""` | When `key` is set, a `NodePool` taint, mirrored as a `ResourceFlavor` toleration |
| `accelerator.methodLabel.key`, `.value` | no | `""` | When `key` is set, a label on the `NodePool`'s node template (`spec.template.metadata.labels`) |
| `tenancy.teamTaint.key`, `.value`, `.effect` | no | `""` | When `key` is set, a team-exclusive `NodePool` taint, mirrored as a `ResourceFlavor` toleration, rendered exactly like `accelerator.taint` |
| `amiFamily`, `amiSelectorTerms` | no | `AL2023`, a pinned AL2023 alias (`al2023@v20261112`) | `EC2NodeClass` AMI selection; the pin is bumped only by a reviewed diff, never `latest` |

This chart is never installed from an upstream chart registry: a cell's own
`gitops/cells/<cluster-name>/capacity-pool/*.yaml` parameter file points
`cells.ApplicationSet.yaml`'s Git file generator at this chart's own `dir`
(RFC #25 Decision 2/3), sets `clusterName`/`nodeRole` through `valuesFrom`
(cell-specific, never a static value in that file - `clusterName` from the
Cluster generator's own `name` param, `nodeRole` from the registration
Secret's annotation), and sets `pool.name` as a static value under its own
`values:` block instead (not cell-specific - the same pool name, `cpu`, is
reused across every cell by this PR's own fixture).

### Reserved pools

A `reserved` pool selects its reservation by tag, never by reservation ID:
a replacement reservation (every Capacity Block purchase is one) is picked
up without editing this release, as long as it carries the same tags.
`instanceMatchCriteria` defaults to `targeted`, because an `open`
reservation can be consumed by any On-Demand launch of the same instance
type in the same Availability Zone anywhere in the account, not only by
this pool. Create the reservation itself as `targeted` too. Karpenter's
`ReservedCapacity` feature gate, which `reserved` relies on, is on by
default in the pinned Karpenter version.

### Taints and tolerations

`accelerator.taint` and `tenancy.teamTaint` are collected into one list
(the `capacity-pool.taints` helper; an entry with an empty `key` is
skipped). The list is rendered as `NodePool.spec.template.spec.taints` and
mirrored as `ResourceFlavor.spec.tolerations`, so a pod Kueue admits
through this flavor tolerates the pool's taints without a hand-written
toleration. Each toleration uses `operator: Equal` with the taint's
`value` when one is set, and `operator: Exists` otherwise. When a `key` is
set, `effect` must be `NoSchedule`, `PreferNoSchedule` or `NoExecute`, and
the two entries must not share the same key and effect; either mistake
fails the render.

### Quotas

`pool.limits` is the only quota-shaped field this chart renders; the
`ResourceFlavor` carries no quota. For an `on-demand` or `flex` pool it is
the budget the admin chooses. For a `reserved` pool, set it to the
reservation's own size (instance count times the instance type's
resources) as a ceiling, and set the `nominalQuota` of the `ClusterQueue`
naming this flavor (for example the smoke chart's `clusterQueue.cpuQuota`
and `clusterQueue.memQuota`) to the same amounts. Nothing links the two:
keep them in step by hand, as with the smoke chart's
`clusterQueue.resourceFlavor`.

## Known limits

- One `NodePool` per release and one capacity type per `NodePool`; a
  fallback from reserved to on-demand capacity is a second release, not a
  value of this one.
- `accelerator` and `tenancy` are values only and enforce nothing by
  themselves. No device plugin selects `accelerator.methodLabel` until the
  accelerator advertisers ship
  ([#19](https://github.com/littlemex/distai-platform/issues/19)), and
  nothing stops another team's `ClusterQueue` from listing a flavor that
  carries `tenancy.teamTaint` until the tenancy admission rules ship
  ([#22](https://github.com/littlemex/distai-platform/issues/22)). Because
  the `ResourceFlavor` tolerates its own taints, any `ClusterQueue` that
  lists the flavor admits pods onto those nodes.
- Not validated by this chart: label and taint key syntax, whether
  `reservation.tags` matches an existing reservation, and whether
  `pool.limits` matches the reservation or the `ClusterQueue`'s quota.
  Karpenter and Kueue reject invalid keys at apply time; a tag that matches
  nothing shows up as a `reserved` pool that never launches a node.
- `EC2NodeClass.spec.role` and the subnet/security-group discovery tags
  assume the foundation layer (`infra/foundation`) created this cell.
