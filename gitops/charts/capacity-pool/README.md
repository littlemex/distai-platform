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
| `pool.labels` | no | Labels on every node launched from the `NodePool` (`spec.template.metadata.labels`), map of string to string; default `{}`. Sets the accelerator method label (`distai.dev/nvidia-gpu-method`, `distai.dev/neuron-method`) the matching `gitops/addons/accel-*` advertiser selects ([#19](https://github.com/littlemex/distai-platform/issues/19) Decision 2) |
| `pool.requirements` | no | Karpenter `NodePool` scheduling requirements; defaults to on-demand, amd64, `c`/`m`/`r` instance categories |
| `pool.limits` | no | Karpenter `NodePool` resource limits; defaults to `cpu: "32"` |
| `pool.disruption` | no | Karpenter `NodePool` disruption settings |
| `amiFamily`, `amiSelectorTerms` | no | `EC2NodeClass` AMI selection; defaults to the latest AL2023 alias |

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
