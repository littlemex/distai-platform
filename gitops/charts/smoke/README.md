# smoke

Admin-owned fixture proving the delivery mechanism end to end before any
team's own queue exists: one `Namespace`, one single-flavor Kueue
`ClusterQueue` and one `LocalQueue`. A canary `Job` (created and deleted per
upgrade e2e run, never stored in Git - RFC #25 Decision 9) targets this
`LocalQueue`; the queue and namespace themselves are permanent.

## Values

| Key | Required | Description |
| --- | --- | --- |
| `namespace` | no | Namespace the `LocalQueue` lives in; default `distai-smoke` |
| `clusterQueue.name` | no | `ClusterQueue`/`LocalQueue` name; default `smoke` |
| `clusterQueue.resourceFlavor` | yes | Name of a `ResourceFlavor` this cell's own `capacity-pool` release creates; cell-specific, never defaulted here |
| `clusterQueue.cpuQuota` | no | Nominal CPU quota; default `"32"` |

Not a team workload: owned by this issue (#25), not by the tenancy layer
(#22), since #22's own per-team queues do not exist yet.
