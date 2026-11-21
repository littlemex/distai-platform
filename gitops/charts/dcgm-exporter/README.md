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
| DCGM mode | embedded (upstream default, unchanged), `hostNetwork: false` | Avoids the `hostPort 5555` conflict with the EKS Node Monitoring Agent's own `dcgm-server` that a standalone, host-network DCGM has |
| `serviceMonitor.enabled` | `false` | No Prometheus Operator CRDs exist in a cell yet, so a `ServiceMonitor` would have no controller to read it |
| `nodeSelector` | `karpenter.k8s.aws/instance-gpu-manufacturer: nvidia` | A Karpenter well-known label on every NVIDIA GPU node, so no device plugin or node-feature label is needed |
| `tolerations` | `operator: Exists` | Lands on tainted GPU nodes too |
| `priorityClassName` | `""` (upstream default is `system-node-critical`) | Must never displace a team's pod on a GPU node; not on the critical boot path |
| `networkPolicy` | enabled, `allowedPeers: [{namespaceSelector: {}}]` | Ingress only from in-cluster pods, only to the metrics port |

## Catalog contract (RFC #41 Decision 4)

| Item | Value |
| --- | --- |
| Default namespace | `dcgm-exporter` |
| Who may create objects in it | Only the admin-owned `Application` that `addons-optional.ApplicationSet.yaml` generates, in the `platform` `AppProject`. No team `AppProject` exists yet, and none may ever list this namespace as a destination, since it is `enforce=privileged` |
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
  change, runs as root (`runAsUser: 0`, `runAsNonRoot: false`), adds the
  `SYS_ADMIN` capability (needed for GPU profiling metrics,
  `DCGM_FI_PROF_*`) and mounts the kubelet pod-resources socket by
  `hostPath`. Pod Security Admission's `baseline` level forbids both, so
  `templates/namespace.yaml` labels the `dcgm-exporter` namespace
  `pod-security.kubernetes.io/enforce: privileged`, on that namespace
  only.
- `hostNetwork` and `hostPID` stay `false`.
- No IAM role or Pod Identity association: the exporter makes no AWS API
  call. Least privilege here is zero AWS permissions, not a scoped-down
  role.
- The `NetworkPolicy` is the upstream chart's own template, rendered from
  `networkPolicy.enabled` and `networkPolicy.allowedPeers`; this wrapper
  only sets those values and ships no `NetworkPolicy` manifest of its own.
  It needs a CNI that enforces `NetworkPolicy`.
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
