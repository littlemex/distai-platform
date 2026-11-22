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

### GPU sub-device sharing (MPS), real-hardware result (2026-11-22)

`accelerator.sharingLabel` is a second, independent label on the NodePool's node
template, additive to `accelerator.methodLabel` (both can be set at once — two
separate keys in the same `metadata.labels` map). It exists for GPU sub-device
sharing opt-in: NVIDIA's own `k8s-device-plugin` chart (the chart behind this
platform's `accel-nvidia-device-plugin` addon) reads a node label named
`nvidia.com/device-plugin.config` to pick a named entry from its own
`config.map`, and splits one physical GPU into `N` MPS replicas when that entry
has a `sharing.mps` block — `sharingLabel.key = "nvidia.com/device-plugin.config"`,
`sharingLabel.value` = the chosen config name (for example `mps-2`). A pool that
never sets this gets no label, so it falls back to the device plugin's own
`config.default` (whole-GPU, no sharing) — unchanged behavior for every existing
pool.

**`nvidia.com/mps.capable=true` is `accelerator.mpsLabel`, baked into the
NodePool's own node template, not a manual `kubectl label` step.** NVIDIA's
`mps-control-daemon` DaemonSet's own node selector needs this label, separate
from the `nvidia.com/device-plugin.config` label `sharingLabel` sets. Setting
it by hand with `kubectl label node` after the node joined does not survive
this chart's own disruption model: any later edit to the same pool's
`requirements` (or, as this chart's own `ec2nodeclass.yaml` renders it,
anything that changes the EC2NodeClass) reads as drift to Karpenter, which
replaces the node — destroying the hand-applied label before the replacement
node's own device-plugin Pod could come up and be relabeled. Every
MPS-opted-in node reached for a test this way showed `nvidia.com/gpu: 0`
allocatable at the moment of use, because the node had just been replaced and
the label was gone (confirmed on real hardware, 2026-11-22). `accelerator.mpsLabel`
closes this by rendering the label in `NodePool.spec.template.metadata.labels`
instead (the same place `methodLabel`/`sharingLabel`/`distai.dev/efa-attached`
already render theirs): Karpenter copies `spec.template.metadata.labels` onto
every node this pool ever launches, including a drift-driven replacement, so
the label is never lost — nothing to reapply, no window where a replaced node
is briefly unlabeled.

**Compared with installing NFD/GPU Feature Discovery (chosen: the
`capacity-pool`-chart label, not NFD/GFD).** NVIDIA's own GPU Operator stack
normally sets `nvidia.com/mps.capable` (and `nvidia.com/gpu.product`,
`nvidia.com/gpu.memory`, etc.) automatically via Node Feature Discovery (NFD)
and the GPU Feature Discovery (GFD) sidecar, reading them off the hardware at
boot. This platform runs neither (device-plugin selection already uses this
chart's own `methodLabel`/`sharingLabel`, not NFD-discovered labels, per #19's
own device-plugin-vs-DRA decision). Installing NFD/GFD only for this one label
was rejected: it adds a second, independent label-setting mechanism (its own
DaemonSet, its own upstream release cadence, its own RBAC) for a value this
platform's own NodePool already knows statically at authoring time — a pool
author who sets `sharingLabel` to an MPS config name already knows, by
construction, that the same pool must be MPS-capable; nothing about this label
needs hardware probing to discover. A static chart value, rendered once at
`helm install`/`upgrade` time and copied onto every node `spec.template`
produces, is strictly less moving infrastructure for the same outcome, and
fails closed the same way every other opt-in field in this chart does — a pool
that never sets `mpsLabel` renders no label and is never selected by
`mps-control-daemon`.

**Confirmed on real hardware, pre-`mpsLabel` baseline** (`g7.8xlarge`,
`us-east-1`, 2026-11-22, manual `kubectl label`): labeling one node
`nvidia.com/device-plugin.config=mps-2` plus (by hand) `nvidia.com/mps.capable=true`
made that node advertise `nvidia.com/gpu: 2` instead of `1` in both `Capacity`
and `Allocatable`, and the real MPS control daemon split the device 50/50
(`set_default_device_pinned_mem_limit 0 16311M`, `set_default_active_thread_percentage 50`
in its own log — both numbers are exactly 100%/`replicas` and the daemon's own
reading of the device's total memory/`replicas` (`16311M`, close to but not
identical to the `31.38 GiB` vLLM itself reports elsewhere on this page as the
device total — which of the two readings is more precise was not checked),
confirmed from the daemon's own log, not computed by this
chart). Two `vllm/agg-baseline` replicas (`engine.replicas=2`, no chart change
needed — each still just requests `nvidia.com/gpu: 1`) both scheduled onto
that one node/GPU, reached `Running`/`Ready` with `RESTARTS=0`, and both
served a real completion independently and concurrently.

**`mpsLabel` itself and its drift-survival proof, confirmed on real hardware**
(`g7.8xlarge`, `us-east-1`): forced an actual Karpenter-driven node replacement
on an MPS-opted-in pool (bumped `pool.rootVolumeSizeGi`, a real EC2NodeClass
hash change, not a simulated drift). The replacement node (confirmed a
genuinely different instance by node name) carried both `nvidia.com/mps.capable=true`
and `nvidia.com/device-plugin.config=mps-2` with zero manual steps, and
`Allocatable`'s `nvidia.com/gpu` read `2` on it immediately — the acceptance
bar this field exists to clear, not merely that Karpenter stamped
`spec.template.metadata.labels` (which it always does, and which alone would
be close to tautological). What is, and is not, independently re-confirmed
here: the node's own labels and allocatable count were read directly after
the replacement; the `mps-control-daemon` Pod's own health was NOT re-observed
at that same moment (`kubectl get pods` showed `1/2 Ready`, `Error`, 2 restarts,
44s after the replacement — Pod-level status; which of its two containers
reported `Error` was not captured, so whether this is the same "config-watcher
sidecar restarts after relabel, main container stays healthy" oddity this
section's own baseline cites is not established either way — no relabel
happened here, which argues against it, but a Pod-level `1/2 Ready` is also
consistent with one container, sidecar included, failing). A real workload
was served from this same node a few minutes later
with `RESTARTS=0` (see `examples/inference/README.md`'s own "MPS" section,
form (a)), which is evidence the daemon had become healthy by then, but that
inference stands in place of a direct re-read of the daemon Pod's own status
at a later timestamp — not yet done.

**Checked on a `Running`/`RESTARTS=0` result, not assumed from it (found by
Fable 5.2 review, 2026-11-22)**: Karpenter's own scheduling simulation decides
whether to launch a node from a pending Pod's request using the instance
type's *physical* resource count, not the device plugin's own future,
MPS-split count (which only exists once the node is `Ready` and the device
plugin has reported it) — so `N` pending replicas, each requesting
`nvidia.com/gpu: 1`, launched close together can in principle land on `N`
separate single-GPU nodes instead of sharing one MPS-split GPU, and still
reach `Running`/`Ready` with `RESTARTS=0` without ever exercising MPS at all.
The real-hardware results in `examples/inference/README.md`'s own "MPS" section name each
replica's own node where that distinction matters most (forms (a) and (b), where both roles are
meant to land on the SAME node) rather than relying on rollout status alone; form (c)'s own rows
name instance types, not node identity, because the open question there is a different one (same
node but possibly different physical GPUs of the 8 — see that section's own stated gap), not
whether Karpenter launched extra nodes.

**Security, reviewed and found incomplete by Fable 5.2 (2026-11-22; recorded as an open
finding, not resolved here)**: NVIDIA's own `mps-control-daemon` DaemonSet — the
process that actually performs the split above, deployed automatically by the
upstream chart whenever any `sharing.mps` config exists, selecting nodes by
`nvidia.com/mps.capable=true` — renders with `hostPID: true`, `privileged: true`
containers, and a `hostPath`-backed `/dev/shm` mount (confirmed by rendering the
upstream chart's own `templates/daemonset-mps-control-daemon.yml`, tag v0.20.2,
default `mps.enableHostPID: true`). This is NVIDIA's own upstream design, not
something this platform's `accelerator.sharingLabel`/`mpsLabel` fields add —
but it means **every MPS-opted-in NodePool already carries a
host-process-namespace-sharing daemon**, independent of and in addition to the
separate `hostIPC` question an earlier round of this same investigation raised
and reverted for the LMCache mp server (see `vllm/disagg-pd/README.md`'s own
"KV cache tiers" section). Four items this round leaves open, not closed:
1. This platform has no admission control (Pod Security Admission, Kyverno, or
   equivalent) rejecting `hostPID`/`privileged`/`hostIPC`/`hostPath` in any
   namespace today. A future fix must add this gate, not rely on README prose
   alone.
2. Nothing in `accelerator.sharingLabel`/`mpsLabel`/this NodePool's own
   requirements restricts *which team's* Pods can request the shared GPU once
   a NodePool carries these labels — two mutually-untrusting teams' Pods could
   both land on one MPS-split GPU unless a separate taint/toleration
   (`tenancy.teamTaint`, already in this chart) also scopes the pool to one
   team. MPS's own per-client limits
   (`CUDA_MPS_ACTIVE_THREAD_PERCENTAGE` and similar) are client-side
   environment variables, not something this platform enforces against a
   hostile tenant; a fatal fault from one MPS client can take down every other
   client sharing that GPU (a cross-tenant denial of service); and GPU memory
   is not zeroed between tenants by MPS or by this platform. Issue #22's own
   existing research already states MPS gives weaker isolation than MIG for
   exactly these reasons — this field's own real deployment shape confirms,
   rather than changes, that guidance: **treat an MPS-opted-in pool as
   single-team/mutually-trusting-workloads only**, never as a way to share one
   GPU across teams that do not trust each other.
3. The blast radius of a shared host namespace (whether via `hostIPC` or
   NVIDIA's own `hostPID`) is the WHOLE host namespace, not narrowly "the two
   Pods that need to talk to each other."
4. **`tenancy.teamTaint` is necessary but not sufficient to actually isolate an
   MPS-opted-in pool to one team, found by Fable 5.2 review, 2026-11-22.** A
   taint only keeps the OTHER team's *workload* Pods off the node; it does not
   by itself keep `nvidia-device-plugin`'s own DaemonSets (the device plugin
   and `mps-control-daemon`) scheduled there either, unless that DaemonSet's
   own `tolerations` already cover the taint's key. This platform's
   `accel-nvidia-device-plugin` addon tolerates only the chart's own defaults
   (`CriticalAddonsOnly`, `nvidia.com/gpu:NoSchedule`) — a `teamTaint` using
   any other key means neither DaemonSet schedules onto that node at all, the
   device plugin never advertises `nvidia.com/gpu`, and the node is unusable
   regardless of `mpsLabel`/`sharingLabel`. This is a pre-existing gap (the
   same interaction already existed for `accelerator.taint` alone, before
   `sharingLabel`/`mpsLabel` existed), not introduced by this round, but
   `teamTaint` is not yet a working *tenancy* control for an MPS pool until
   the addon's own tolerations are made configurable per pool (or `teamTaint`
   is restricted to keys the addon already tolerates) — tracked, not fixed,
   here.

**What this mechanism actually exposes, stated precisely rather than
overclaimed** (confirmed against the upstream chart's own README, `NVIDIA/k8s-device-plugin`
tag v0.20.2): the only tunable `sharing.mps.resources[].replicas` gives is the
replica *count* — compute and memory are always split into **equal** shares
across however many replicas a config names. There is no separate,
independently settable `CUDA_MPS_ACTIVE_THREAD_PERCENTAGE` or per-client
memory-limit value in this config schema; an unequal split is not expressible
through `accelerator.sharingLabel`/`mpsLabel` at all. A minor, non-blocking
rough edge observed on real hardware: the `mps-control-daemon` DaemonSet's own
config-watcher *sidecar* container restarts repeatedly after a node relabel
(`error finding pid: no process found`), while the daemon's own main container
stays `Running` and healthy throughout and the capacity/split above were both
confirmed correct regardless — tracked as an upstream oddity, not a defect in
this chart's own rendering.

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
