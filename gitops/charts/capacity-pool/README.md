# capacity-pool

One Karpenter `NodePool`, its `EC2NodeClass` and the matching Kueue
`ResourceFlavor`, as a single release. This is the minimal CPU-only skeleton
RFC #25's first PR ships (one capacity type, no reserved/on-demand/flex
ordering across several `NodePool`s of the same pool). [#17](https://github.com/littlemex/distai-platform/issues/17)
extends this chart with that logic on top; this chart's name, values shape
and the three kinds it renders do not change under that extension.

## Values

| Key | Required | Description |
| --- | --- | --- |
| `clusterName` | yes | Matches the `karpenter.sh/discovery` tag the foundation layer puts on the cell's subnets and security group |
| `nodeRole` | yes | IAM role name for nodes launched by Karpenter (`infra/foundation` output `karpenter_node_role_name`) |
| `pool.name` | yes | Name shared by the `NodePool`, its `EC2NodeClass` and the `ResourceFlavor` |
| `pool.requirements` | no | Karpenter `NodePool` scheduling requirements; defaults to on-demand, amd64, `c`/`m`/`r` instance categories |
| `pool.limits` | no | Karpenter `NodePool` resource limits; defaults to `cpu: "32"` |
| `pool.disruption` | no | Karpenter `NodePool` disruption settings |
| `pool.networkInterfaces` | no | `EC2NodeClass.spec.networkInterfaces`; empty by default (no extra ENI). Set this to request an EFA device on an EFA-capable instance type - Karpenter does not attach one on its own just because the instance type supports it (confirmed against upstream's NodeClasses doc, 2026-11-20). For a single-network-card type (one EFA interface, for example the `g7`/`g7e` sizes below `.48xlarge`): `[{networkCardIndex: 0, deviceIndex: 0, interfaceType: interface}, {networkCardIndex: 0, deviceIndex: 1, interfaceType: efa-only}]`. For a two-network-card type (two EFA interfaces, for example `g7.48xlarge` - needed to co-locate two EFA-requesting Pods, such as `disagg-pd`'s `placement.sameNodeMeasurement`, on one node at all, since the device plugin never gives two Pods the same interface; confirmed on real hardware, `g7.48xlarge`, 2026-11-20): `[{networkCardIndex: 0, deviceIndex: 0, interfaceType: interface}, {networkCardIndex: 0, deviceIndex: 1, interfaceType: efa-only}, {networkCardIndex: 1, deviceIndex: 0, interfaceType: efa-only}]`. Instance types vary widely in network card count - `p5en.48xlarge` has 16, not 2 (confirmed via `aws ec2 describe-instance-types`, 2026-11-21); extend the pattern above with one more `{networkCardIndex: N, deviceIndex: 0, interfaceType: efa-only}` entry per additional card actually wanted. |
| `pool.rootVolumeSizeGi` | no | `""` | `EC2NodeClass` root volume size (e.g. `"100Gi"`); default renders no `blockDeviceMappings` at all, so the node's root volume stays the AMI's own default size |
| `amiFamily`, `amiSelectorTerms` | no | `EC2NodeClass` AMI selection; defaults to a pinned AL2023 alias (`al2023@v20261112`), bumped only by a reviewed diff, never `latest` |

This chart is never installed from an upstream chart registry: a cell's own
`gitops/cells/<cluster-name>/capacity-pool/*.yaml` parameter file points
`cells.ApplicationSet.yaml`'s Git file generator at this chart's own `dir`
(RFC #25 Decision 2/3), and sets `clusterName`/`nodeRole`/`pool.name` through
`valuesFrom`, not a static value in that file.

## Known limits

- One `NodePool` per release, one capacity type (on-demand) - this PR's own
  minimal skeleton, extended by #17.
- `EC2NodeClass.spec.role` and the subnet/security-group discovery tags
  assume the foundation layer (`infra/foundation`) created this cell.
