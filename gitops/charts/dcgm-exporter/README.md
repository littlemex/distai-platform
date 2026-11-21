# dcgm-exporter

A thin wrapper around NVIDIA's own
[`dcgm-exporter`](https://github.com/NVIDIA/dcgm-exporter) Helm chart
(version `4.9.0`, pinned in `Chart.yaml` with its tarball digest). It runs
one `DaemonSet` pod on every NVIDIA GPU node and exposes GPU metrics in
Prometheus exposition format on a `ClusterIP` `Service`, port `9400`. It
produces metrics only; it does not scrape, store or display them.

This is a `tier: platform-optional` component (RFC
[#41](https://github.com/littlemex/distai-platform/issues/41) Decision 1).
Its catalog entry is `gitops/addon-catalog/dcgm-exporter/addon.yaml`; a cell
opts in with a marker file, `gitops/cells/<cluster-name>/addons/dcgm-exporter.yaml`,
which `gitops/appsets/addons-optional.ApplicationSet.yaml` turns into one
`Application` for that cell only. It covers the exporter half of
[#33](https://github.com/littlemex/distai-platform/issues/33); alerting
waits on a `prometheus` catalog entry.

The upstream chart is a Helm `dependencies:` entry, so its default values
sit under the `dcgm-exporter:` key in this chart's `values.yaml`, and a
marker's override paths carry the same prefix. Run
`helm dependency build gitops/charts/dcgm-exporter` before `helm lint` or
`helm template`; the fetched `charts/` directory is git-ignored, and
`Chart.lock` records the resolved version.

## Defaults this wrapper sets

| Value | Setting | Reason |
| --- | --- | --- |
| DCGM mode | embedded (nothing to set; the upstream chart has no values.yaml key for this) | Avoids a running DCGM host engine this platform does not operate |
| `hostNetwork` | `false` (matches the upstream default, pinned explicitly so a future version bump cannot silently flip it) | Avoids the `hostPort 5555` conflict with the EKS Node Monitoring Agent's own `dcgm-server` that a standalone, host-network DCGM has |
| `resources` | the upstream chart's own `4.9.0` defaults, copied in explicitly for the same reason as `hostNetwork` | A reviewed diff in this repository, not a silent upstream change, is what moves this platform's resource footprint |
| `serviceMonitor.enabled` | `false` | No Prometheus Operator CRDs exist in a cell yet, so a `ServiceMonitor` would have no controller to read it |
| `nodeSelector` | `karpenter.k8s.aws/instance-gpu-manufacturer: nvidia` | A Karpenter well-known label on every NVIDIA GPU node, so no device plugin or node-feature label is needed |
| `tolerations` | `operator: Exists` | Lands on tainted GPU nodes too |
| `priorityClassName` | `""` (upstream default is `system-node-critical`) | Must never displace a team's pod on a GPU node; not on the critical boot path |
| `networkPolicy` | enabled, `allowedPeers: [{namespaceSelector: {}}]` | Ingress only from in-cluster pods, only to the metrics port |

## Catalog contract (RFC #41 Decision 4)

| Item | Value |
| --- | --- |
| Default namespace | `dcgm-exporter` |
| Who may create objects in it | Only the admin-owned `Application` that `addons-optional.ApplicationSet.yaml` generates, in the `platform` `AppProject`, today -- the only `AppProject` that exists. Once [#22](https://github.com/littlemex/distai-platform/issues/22) ships a team `AppProject`, that project's own destination allow-list is what must exclude this `enforce=privileged` namespace; nothing enforces that today, since #22's own mechanism does not exist yet to check against |
| `dependsOn` | None today. RFC #41 Decision 5 names `prometheus`; it is added once that catalog entry exists (see the catalog entry's own comment) |
| Infra prerequisites | At least one `NodePool` in the cell that launches NVIDIA GPU instances. Without one, the `DaemonSet` schedules no pod and costs nothing |
| Overridable by a cell | `dcgm-exporter.resources` and `dcgm-exporter.networkPolicy.allowedPeers` only (`overridableKeys` in the catalog entry) |
| Owner | `@littlemex` |

### Resource footprint

Per GPU node, one pod, using the upstream chart's own default `resources`
(read from its `values.yaml` at version `4.9.0`; this wrapper does not
change them):

| | CPU | Memory | Ephemeral storage |
| --- | --- | --- | --- |
| Requests | `100m` | `128Mi` | `100Mi` |
| Limits | `200m` | `512Mi` | - |

One replica per node, so no `PodDisruptionBudget` applies; the upstream
`DaemonSet` rolls one node at a time (`maxUnavailable: 1`).

### Security notes

- The upstream chart's own default pod spec, which this wrapper does not
  change, runs as root (`runAsUser: 0`, `runAsNonRoot: false`) and adds
  the `SYS_ADMIN` capability, needed for GPU profiling metrics
  (`DCGM_FI_PROF_*`: SM occupancy, tensor/FP64 pipe utilization, NVLink
  throughput -- exactly the per-job GPU utilization signal this
  platform's own training/inference workloads need, not a feature this
  component happens to also offer). Dropping `SYS_ADMIN` was considered
  and rejected for that reason: the real benefit would be a narrower
  container capability set, not a lower Pod Security level -- the chart
  also mounts the kubelet pod-resources socket by `hostPath` (reads
  GPU-to-pod assignment for per-pod metric labels), a second,
  independent reason this namespace needs `privileged` regardless of
  `SYS_ADMIN`, so dropping the capability alone would not let this
  namespace move off `privileged`. Either one alone already requires
  `templates/namespace.yaml`'s `pod-security.kubernetes.io/enforce:
  privileged` label, on the `dcgm-exporter` namespace only
  (`warn`/`audit` stay at `baseline`, matching the `distributed-ai`
  `image-builder.tf` precedent RFC #41's own Facts table cites).
- `hostNetwork` and `hostPID` stay `false`.
- No IAM role or Pod Identity association: the exporter makes no AWS API
  call. Least privilege here is zero AWS permissions, not a scoped-down
  role.
- The `NetworkPolicy` is the upstream chart's own template, rendered from
  `networkPolicy.enabled` and `networkPolicy.allowedPeers`; this wrapper
  only sets those values and ships no `NetworkPolicy` manifest of its own.
  It needs a CNI that enforces `NetworkPolicy` -- `infra/foundation`
  already turns this on (`eks.tf`'s VPC CNI `enableNetworkPolicy: "true"`),
  so every cell this chart can run on already enforces it.
- The upstream chart creates a `ClusterRole` and binding
  (`kubernetes.rbac.create: true`, its default) to read pod metadata for
  metric labels.

### Removal checklist

Deleting the cell's marker file removes the `Application`, but
`addons-optional.ApplicationSet.yaml` sets
`preserveResourcesOnDeletion: true`, so the `DaemonSet`, `Service`,
`NetworkPolicy`, RBAC objects and the namespace stay in the cluster,
orphaned. Nothing else needs cleaning up for the platform to keep working.
To remove them as well, delete the `dcgm-exporter` namespace and the
chart's `ClusterRole`/`ClusterRoleBinding` by hand after the marker file's
pull request merges.
