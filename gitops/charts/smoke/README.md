# smoke

Admin-owned fixture proving the delivery mechanism end to end before any
team's own queue exists: one `Namespace`, one single-flavor Kueue
`ClusterQueue` restricted to that namespace, and one `LocalQueue`. A
canary workload (a `Job` in `gitops/tests/1.e2e.sh`, a bare `Pod` in `2.upgrade.sh`,
created and deleted per e2e run, never stored in Git - RFC #25 Decision 9)
targets this `LocalQueue`; the queue and namespace themselves are
permanent.

## Values

| Key | Required | Description |
| --- | --- | --- |
| `namespace` | no | Namespace the `LocalQueue` lives in, and the only one the `ClusterQueue`'s `namespaceSelector` admits; default `distai-smoke` |
| `clusterQueue.name` | no | `ClusterQueue` name; default `smoke` |
| `clusterQueue.resourceFlavor` | yes | Name of a `ResourceFlavor` this cell's own `capacity-pool` release creates; cell-specific, never defaulted here |
| `clusterQueue.cpuQuota` | no | Nominal CPU quota; default `"32"` |
| `clusterQueue.memQuota` | no | Nominal memory quota; default `"64Gi"` |
| `localQueue.name` | no | `LocalQueue` name (its own `spec.clusterQueue` always points at `clusterQueue.name`, so the two names may differ); default `smoke` |

Not a team workload: owned by this issue (#25), not by the tenancy layer
(#22), since #22's own per-team queues do not exist yet.
