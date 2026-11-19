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
| `pool.rootVolumeSizeGi` | no | `""` | `EC2NodeClass` root volume size (e.g. `"100Gi"`); default renders no `blockDeviceMappings` at all, so the node's root volume stays the AMI's own default size |
| `pool.networkInterfaces` | no | `[]` | `EC2NodeClass.spec.networkInterfaces`; empty by default (no extra ENI). Set this to request an EFA device on an EFA-capable instance type - Karpenter does not attach one on its own just because the instance type supports it (confirmed against upstream's NodeClasses doc, 2026-11-20). For a single-network-card type (one EFA interface, for example the `g7`/`g7e` sizes below `.24xlarge`): `[{networkCardIndex: 0, deviceIndex: 0, interfaceType: interface}, {networkCardIndex: 0, deviceIndex: 1, interfaceType: efa-only}]` |
| `reservation.tags` | when `reserved` | `{}` | Tags selecting the Capacity Reservation(s) or Capacity Block(s) backing a `reserved` pool. Must be non-empty, with no empty key or value, when `pool.capacityType` is `reserved`; ignored otherwise |
| `reservation.instanceMatchCriteria` | no | `targeted` | `targeted` or `open`; any other value fails the render. Used only when `pool.capacityType` is `reserved` |
| `accelerator.resourceName` | no | `""` | When set, rendered as the annotation `distai.dev/accelerator-resource-name` on the `NodePool` and the `ResourceFlavor` (for example `nvidia.com/gpu`, `aws.amazon.com/neuron`). Provenance only: no template branches on its value |
| `accelerator.taint.key`, `.value`, `.effect` | no | `""` | When `key` is set, a `NodePool` taint, mirrored as a `ResourceFlavor` toleration |
| `accelerator.methodLabel.key`, `.value` | no | `""` | When `key` is set, a label on the `NodePool`'s node template (`spec.template.metadata.labels`) -- the accelerator method label a matching `gitops/addons/accel-*` advertiser selects nodes by ([#19](https://github.com/littlemex/distai-platform/issues/19) Decision 2) |
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
the budget the admin chooses. For a `reserved` pool, `pool.limits` is a
Karpenter-side ceiling Karpenter itself accounts in instance-type
capacity, not in Kubernetes allocatable: set it to the reservation's
instance count times each instance type's own full, advertised resources
(this PR's own real-cluster verification sets `pool.limits` this way --
the reservation's own vCPU and memory, read from `DescribeInstanceTypes` --
and a single reserved node launched and admitted a workload under it). A
smaller, allocatable-based number here would already be below one
instance's own full capacity, so Karpenter would refuse to launch that
instance type for this pool at all, before any pod is even scheduled --
not after the fact, but as a precondition it never clears.
The `nominalQuota` of the `ClusterQueue` naming this flavor (for example
the smoke chart's `clusterQueue.cpuQuota` and `clusterQueue.memQuota`) is
a separate number for a separate purpose: Kueue admits against pod
requests, so a pod's own request must still fit in a node's real
Kubernetes allocatable capacity regardless of what `nominalQuota` says;
sizing `nominalQuota` to the same full-capacity number as `pool.limits`
(as tested here) is a workable budget as long as individual pod requests
stay below the node's actual allocatable, with no safety margin if a
request approaches the full number; a more conservative, smaller
`nominalQuota` trades some admittable capacity for that margin. Nothing
links `pool.limits` and the `ClusterQueue`'s `nominalQuota`: keep them in
step by hand, as with the smoke chart's `clusterQueue.resourceFlavor`.

## Known limits

- One `NodePool` per release and one capacity type per `NodePool`; a
  fallback from reserved to on-demand capacity is a second release, not a
  value of this one.
- `reservation.instanceMatchCriteria: open` renders (Karpenter accepts
  both values), but `gitops/tests/check_gitops_contract.py` rejects it for
  every tracked `cells/*/capacity-pool/*.yaml` file in this repository --
  the chart stays generic, the repository's own house rule (never `open`,
  per #22 Decision 10 H9) is enforced once, at the content-contract layer,
  not duplicated into the template as a second, chart-level restriction.
- This PR's own real-cluster verification exercised an On-Demand Capacity
  Reservation, not a Capacity Block; `capacityReservationSelectorTerms`
  does not distinguish the two (Karpenter's own docs: both are selected
  the same way), but their own ending is not the same event. An On-Demand
  Capacity Reservation's own `EndDate` only ends the reservation itself:
  any instance already running in it keeps running, billed as an
  ordinary On-Demand instance from then on, with nothing forcibly
  stopped. A Capacity Block for ML has a hard end AWS enforces by
  reclaiming the capacity, which is why the foundation layer wires its
  own `capacity-reservation` EventBridge rule to Karpenter's
  interruption queue (per #20/#21): without it, Karpenter has no warning
  before a Capacity Block's instances are taken back. This PR's own
  verification exercised neither a Capacity Block nor that interruption
  path. Before a Capacity Block's own start time (or an ODCR not yet
  active), `capacityReservationSelectorTerms` resolves nothing yet, so a
  `-rsv` pool with no other capacity type behaves as if no capacity
  exists at all (Kueue admits, Karpenter cannot launch) -- not solved
  here.
- If `pool.limits` or the matching `ClusterQueue`'s `nominalQuota`
  (Quotas, above) is set larger than the reservation can actually hold --
  more instances' worth than the reservation's own instance count --
  Kueue can admit a workload the reservation has no room for; it is then
  stuck `Pending` after admission, the exact "admission does not always
  mean capacity" failure #17 describes for `-od`/`-flex`, now possible on
  a misconfigured `-rsv` pool too.
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
- **Root caused on real hardware: a node's own root volume can be too
  small for a realistic container image, and the failure this produces
  reads as an unrelated scheduling or consolidation problem until traced
  end to end.** Before this chart took `pool.rootVolumeSizeGi`, a
  `trn2.3xlarge` node's `EC2NodeClass` rendered no `blockDeviceMappings`
  at all, so its root volume stayed the AMI's own default. A `kubectl get
  events` trace during a real failure showed a verification pod
  genuinely `Scheduled` and bound to that node, then evicted twice by
  kubelet as a 7.5 GiB container image's pull consumed the root volume
  (`"The node was low on resource: ephemeral-storage"`), with the pull
  itself failing (`"no space left on device"` while extracting a layer).
  Only once the pod was evicted and gone did the node look idle to
  Karpenter's own disruption controller, which reclaimed it as `Empty`
  (`"pod-count":0`) a short time later -- read in isolation, this last
  log line alone is indistinguishable from "the pod was never bound",
  and two earlier, less complete investigations of the same failure each
  concluded exactly that before this full trace corrected them. Any
  consumer of this chart running a realistically-sized image on any pool
  it creates, reserved/on-demand/flex alike, is exposed to the identical
  failure until `pool.rootVolumeSizeGi` is set large enough for that
  image.
- **A `flex` pool (`pool.capacityType: flex`, `karpenter.sh/capacity-type In
  [spot, on-demand]`) whose `pool.requirements` name exactly one instance
  type can retry spot forever and never actually launch on-demand, even
  while on-demand capacity is confirmed available.** Root caused on a real
  run ([#28](https://github.com/littlemex/distai-platform/issues/28)
  section H), a `trn` `NodePool` whose only instance-type requirement is
  `karpenter.k8s.aws/instance-family In [trn2]` (`trn2.3xlarge` is the only
  Trainium2 size, so this is a single-offering `NodePool`, not a chart
  defect specific to this fixture -- any consumer naming exactly one
  instance type on a `flex` pool is exposed the same way). Over a 30-minute
  wait for one pending pod:
  - 9 real `CreateFleet` calls (confirmed via CloudTrail, filtered by the
    cell's own `eks:eks-cluster-name` resource tag), roughly one every
    `3m10s`, every one `TargetCapacitySpecification.DefaultTargetCapacityType:
    spot`, every one returning `aws-status-code: 200` with a per-instance-type
    fleet error `UnfulfillableCapacity` -- never a single real `on-demand`
    attempt.
  - A separate *dry-run* `CreateFleet` for the same instance type, issued at
    the very start, set `DefaultTargetCapacityType: on-demand` and returned
    `"errorCode":"Client.DryRunOperation"`,
    `"errorMessage":"Request would have succeeded, but DryRun flag is set."`
    -- on-demand capacity was confirmed available the whole time this
    NodePool kept retrying spot only.
  - The `~3m10s` cadence between retries is consistent with the AWS cloud
    provider's own unavailable-offerings cache TTL (3 minutes), which is
    directly cited, with its exact source line, in a closed upstream report
    of the same cache behavior
    ([kubernetes-sigs/karpenter#2275](https://github.com/kubernetes-sigs/karpenter/issues/2275)).
    *What is directly observed is the three bullets above (timing, request
    parameters, response codes); the explanation of **why** Karpenter
    re-selects spot every time that cache entry expires -- its own
    price-based offering ranking has no second instance type to diversify
    across once the sole offering's cache entry clears, so the cheaper
    (spot) option looks viable again and is re-tried -- is this
    repository's own inference from the evidence and from the cited
    upstream issues, not something confirmed by reading Karpenter's own
    scheduling source directly.*
  - This matches the top-level symptom of
    [aws/karpenter-provider-aws#9616](https://github.com/aws/karpenter-provider-aws/issues/9616)
    ("a NodePool with `capacity-type In [spot, on-demand]` keeps retrying
    the same (spot) capacity type and never falls back to on-demand"), but
    that report's own root cause is a *different* code path -- an
    API-level `CreateFleet` error (e.g. `InternalError`) that bypasses the
    unavailable-offerings cache entirely, so no offering is ever marked
    unavailable at all. Every real attempt observed here returned a normal
    `200` status with a per-instance-type fleet error, which the AWS
    provider's own cache-update path does walk (consistent with the
    observed `~3m10s` cache-driven cadence) -- the opposite starting
    condition from #9616's bypassed-cache case, arriving at the same
    "fallback never engages" outcome by a different route. No upstream
    report matching this exact route (cache populated and expiring
    normally, capacity-type fallback still never taken for a
    single-instance-type pool) was found; see #28 for whether one is
    worth filing.
  - `pool.capacityType: on-demand` instead of `flex` was tried next as a
    workaround, once a `NodePool`'s own `pool.requirements` narrow it to a
    single instance type and the verification does not need spot
    specifically. On a real run it failed a different way, now root
    caused: `aws pricing get-products` for `trn2.3xlarge` returns an
    **empty `PriceList` in every region checked**, including `us-east-1` --
    AWS has not published an on-demand price for this instance type at
    all yet. This matches
    [aws/karpenter-provider-aws#3585](https://github.com/aws/karpenter-provider-aws/issues/3585)
    ("Support Preview Instance Types"): a new instance type can show up in
    `DescribeInstanceTypes`/`DescribeInstanceTypeOfferings` and pass a
    dry-run `CreateFleet`, but with no `pricing.GetProducts` entry,
    Karpenter's own price-based allocation strategy (`lowest-price` for
    on-demand, confirmed in this chart's own `CreateFleet` request
    parameters) can never select it for a real launch -- Karpenter issued
    only `DryRunOperation` `CreateFleet` calls (every one reporting it
    would have succeeded) and zero real ones for the full 30-minute wait.
    Spot uses a different data source (EC2's own live Spot Price History,
    not the centralized Price List API), which does have data for
    `trn2.3xlarge`, so spot is the *only* capacity type Karpenter can
    actually launch this instance type through right now -- `flex`'s own
    "sticks to spot" behavior (above) is therefore not a preference
    artifact to route around for this instance type, it is the only
    structurally available path, until AWS publishes the missing price.
    This chart renders either `capacityType` value; whether a given
    instance type has a usable on-demand path at all is outside this
    chart's own control.

## Confirmed on real hardware

- **2026-11-22, `p4d.24xlarge` x2, `pool.networkInterfaces` multi-card EFA array (case 3: every
  card EFA-capable, same shape as `p5.48xlarge`/`p5e.48xlarge`/`p5en.48xlarge` -- see
  [#50](https://github.com/littlemex/distai-platform/issues/50)).** Run as a stand-in for the
  upcoming `p5en.48xlarge` x2 Capacity Block, on `spot` capacity, a disposable foundation cell in
  `ap-northeast-1`, to find chart/admission defects before the real block (`helm template` alone
  cannot catch an admission-webhook rejection -- the same lesson the foundation layer's own real run
  already drew for `node.kubernetes.io/instance-type`). `pool.requirements` used
  `node.kubernetes.io/instance-type` (never `karpenter.k8s.aws/instance-type`, which Karpenter's own
  admission webhook rejects) with a single value; `pool.networkInterfaces` was the 5-entry array
  `{0,0,interface}`, `{0,1,efa-only}`, `{1,1,efa-only}`, `{2,1,efa-only}`, `{3,1,efa-only}`
  (`p4d.24xlarge` has 4 network cards, all 4 EFA-capable).
  - `helm upgrade --install` against a real cluster rendered a valid `EC2NodeClass`/`NodePool`/
    `ResourceFlavor`; both reached `Ready: True`.
  - A pending workload (2 Pods, one per host, 8x `nvidia.com/gpu` and 4x `vpc.amazonaws.com/efa`
    each) triggered two real `NodeClaim`s, both `Launched: True` within under a minute, both real
    `p4d.24xlarge` Spot instances.
  - `aws ec2 describe-instances` on a launched instance confirmed all 5 interfaces `in-use` at the
    exact `NetworkCardIndex`/`DeviceIndex` requested (plus the usual extra pod-networking ENI the
    VPC CNI attaches after boot, unrelated to this array).
  - On the real node: `lspci` listed 4 `Elastic Fabric Adapter (EFA)` devices; `ls
    /sys/class/infiniband` listed exactly 4 `rdmap*` devices; the `efa` kernel module was loaded.
    `nvidia.com/gpu` allocatable was `8` on both nodes with no extra add-on
    (`accel-nvidia-device-plugin` alone was enough).
  - `vpc.amazonaws.com/efa` allocatable required a separate `aws-efa-k8s-device-plugin` DaemonSet
    (this chart's own `networkInterfaces` field only asks EC2 to attach the hardware; nothing in
    this repository yet advertises it as a Kubernetes extended resource). Mounting only
    `/var/lib/kubelet/device-plugins` was not enough -- the plugin logged "No devices found" and
    exited clean (`Completed`, not `CrashLoopBackOff`, which reads as a quiet success at a glance).
    It also needs `/sys` and `/dev` mounted into the container and `securityContext.privileged:
    true`; with all three, it found all 4 devices on both nodes and `vpc.amazonaws.com/efa`
    allocatable read `4`.
  - A real 2-node, 16-GPU `all_reduce_perf` (OpenMPI, `FI_PROVIDER=efa`) completed end to end over
    `NET/Libfabric/.../GDRDMA` (confirmed in the NCCL log -- not a sockets fallback), 0 out-of-bounds
    values, ~76.7 GB/s bus bandwidth at a 2 GiB message size.
  - `fi_info -p efa 2>&1 | grep -c "^provider: efa"` printed 12, not 4, on this libfabric build
    (`version: 206.0` lists each physical device under both the `efa-direct` and classic `efa`
    fabrics, 3 provider lines per device) -- a reminder that this specific one-liner is
    libfabric-version-dependent; `ls /sys/class/infiniband | wc -l` (or counting unique `domain:`
    names with the `-rdm`/`-dgrm` suffix stripped) is the version-independent check.
  - Dedicated GPU, EFA-aware teardown was not exercised beyond this run's own terminate +
    `terraform destroy` + an independent AWS-API leftover sweep (zero instances, ENIs, volumes,
    launch templates or placement groups left under this run's own tags/prefix afterward).
