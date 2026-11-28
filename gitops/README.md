# gitops

Everything that runs inside a cell, delivered by the EKS managed Argo CD
capability `infra/foundation` creates (hub cells only). Terraform's state
graph never contains a Kubernetes object once a cell exists (RFC
[#17](https://github.com/littlemex/distai-platform/issues/17),
[#19](https://github.com/littlemex/distai-platform/issues/19)); this
directory, delivered through Argo CD, is the only place any chart, CRD,
`NodePool` or workload is declared. The mechanism common to every add-on
and every cell is defined in RFC
[#25](https://github.com/littlemex/distai-platform/issues/25) ("the
delivery layer"); this README is the condensed, operational version of
that RFC.

## Layout

```text
gitops/
  bootstrap/
    bootstrap.sh                 # run once per cell, after terraform apply
    root-application.yaml        # template bootstrap.sh applies
  appsets/
    platform.ApplicationSet.yaml # one Application per gitops/addons/*/addon.yaml
    cells.ApplicationSet.yaml    # one Application per gitops/cells/<cell>/{capacity-pool,smoke,sharedfs}/*.yaml
    addons-optional.ApplicationSet.yaml # one Application per gitops/cells/<cell>/addons/*.yaml
  addons/
    <name>/addon.yaml            # one platform-wide add-on: chart, version, wave, values (tier: core)
  addon-catalog/
    <name>/addon.yaml            # one reviewed platform-optional entry; never read by an ApplicationSet
  charts/
    <name>/                      # shared chart templates, parameterized per cell
  cells/
    <cluster-name>/
      capacity-pool/*.yaml        # one parameter file per NodePool
      smoke/*.yaml                 # the admin-owned smoke ClusterQueue/LocalQueue
      sharedfs/*.yaml               # this cell's static PersistentVolume + FilesystemShare objects (#18)
      addons/*.yaml                # one marker file per platform-optional component this cell opts into
```

Directories are named by **ownership and kind**, not by sync order: a wave
renumbering is a one-line edit inside an `addon.yaml` or cell parameter
file, never a directory move (RFC #25 Decision 3). `appsets/`, `bootstrap/`,
`addons/`, `charts/` and `cells/*/capacity-pool/`, `cells/*/smoke/` are
covered today by this repository's single, repository-wide `.github/CODEOWNERS`
entry (`* @littlemex`) -- which also covers every other path, including
`cells/*/teams/*` once #22 ships, so nothing in `CODEOWNERS` yet
distinguishes an admin path from a team one; a path-specific rule drawing
that line is #22's own to add.

## Tiers

Every component is one of three tiers (RFC
[#41](https://github.com/littlemex/distai-platform/issues/41)). **core**
ships to every cell with no opt-out: an `addons/<name>/addon.yaml` with
`tier: core`, delivered by `platform.ApplicationSet.yaml`.
**platform-optional** is an admin-delivered capability a cell opts into:
its reviewed definition is `addon-catalog/<name>/addon.yaml`, and a marker
file `cells/<cluster-name>/addons/<name>.yaml` (naming it in `fromCatalog`)
is the opt-in, delivered by `addons-optional.ApplicationSet.yaml`. A
component with no node-placement need of its own lands on the core
`optional-pool` `NodePool`, never the system node group (whether that
pool exists is still an open choice, see
`charts/optional-pool/README.md`); `dcgm-exporter`, the first shipped
entry, is the opposite case -- its own `nodeSelector` targets GPU nodes
specifically, so it never schedules onto `optional-pool` at all. A
wrapped upstream chart is pinned in the wrapper's own `Chart.yaml`, not
in an `addon.yaml`. **workload** is scoped to one team and has no delivery path until
[#22](https://github.com/littlemex/distai-platform/issues/22) ships.

### `wave` and "optional" each name more than one thing

Both terms are overloaded across this platform (#63, filed as #61 item
3); this is the one place that lists every meaning rather than leaving
a reader to infer which one applies from context.

`wave` is:
- A named ordering step for **core** add-ons and cells: `crds`,
  `controllers`, `accelerators`, `capacity` (see Ordering below) --
  these values gate `platform.ApplicationSet.yaml`'s/`cells.ApplicationSet.yaml`'s
  own sync order, and nothing else reads them.
- A numbered slot for **platform-optional** add-ons instead:
  `optional-1`, `optional-2`, ... (for example
  `cells/<cluster>/addons/dcgm-exporter.yaml`'s `wave: optional-1`) --
  `addons-optional.ApplicationSet.yaml`'s own `dependsOn` ordering reads
  these, a different mechanism from the named core steps above, sharing
  only the field name.

"optional" is, separately:
- A tier name: **platform-optional** (above).
- A core add-on's own name: `optional-pool`, the admin-owned `NodePool`
  every cell gets regardless of tier.
- That add-on's own rendered object name: `optional-pool` (the
  `NodePool`/`EC2NodeClass` Karpenter actually creates).
- A wave-value prefix: the `optional-N` numbering immediately above.

None of these four refer to each other; reading "optional" or `wave` in
one file never implies the meaning it carries in a different one.

## Bootstrapping a cell (once, after `terraform apply`)

A freshly-applied cell has a running Argo CD capability with zero
registered clusters, and an access entry that carries only the two
built-in Argo-CD-capability-management policies (letting the capability
manage itself, never `AmazonEKSClusterAdminPolicy`) until
`infra/foundation`'s `aws_eks_access_policy_association` grants that too.
Run this
once per cell, and again whenever a PR adds a new chart registry (see
Versioning below):

```bash
cd infra/foundation
aws eks update-kubeconfig --name "${NAME}" --region "${AWS_REGION}"
../../gitops/bootstrap/bootstrap.sh --tf-outputs <(terraform output -json)
```

This writes exactly three objects, all in the capability's own namespace:
a `cell-registration` `Secret` (labelled `argocd.argoproj.io/secret-type:
cluster`, `server` set to the cluster's ARN - never an API server URL),
the `platform` `AppProject`, and a root `Application` sourced at
`gitops/appsets/`. Everything after that point is Git, not a script: the
root `Application` delivers `platform.ApplicationSet.yaml`,
`cells.ApplicationSet.yaml` and `addons-optional.ApplicationSet.yaml`,
which deliver every add-on, every cell's own capacity and every
platform-optional component a cell opts into.

The script is idempotent: re-running it with the same inputs changes
nothing. It aborts before writing anything if the live `kubectl` context's
cluster does not match `--tf-outputs`, or if a `cell-registration` Secret
already exists naming a *different* cluster - it never overwrites another
cell's registration under the same name.

## The `platform` `AppProject` is an admin boundary, not a tenant one

Every `Application` this platform generates (`platform.ApplicationSet.yaml`
and `cells.ApplicationSet.yaml` alike) uses the one `platform` `AppProject`,
and `var.argocd.role_mappings`' `ADMIN`/`EDITOR` roles (`VIEWER` is
read-only within the project and does not change what follows) are
roles *within that one project* - there is no narrower, per-team project
until #22 ships. `destinations.namespace` and `sourceRepos` are computed by
`bootstrap.sh` from this checkout's own `gitops/addons/*/addon.yaml`,
`gitops/addon-catalog/*/addon.yaml` and `gitops/cells/*/{capacity-pool,
smoke}/*.yaml` at `HEAD`, the same way, every run: only the namespaces and
chart registries an addon or cell parameter file actually declares (plus
`kube-system`, always included - Karpenter's and Kueue's own pinned
charts each render a second RBAC object there regardless of either
chart's own configured namespace, confirmed by rendering both), never
`"*"`. `clusterResourceWhitelist`/`namespaceResourceWhitelist` are a
hand-maintained, reviewed list in `gitops/bootstrap/appproject-whitelist.yaml`
(not `"*"`/`"*"` either), derived by rendering every addon and cross-checked
by `gitops/tests/check_appproject_whitelist.py` - see that file's own
header comment for why this list is hand-maintained rather than derived
live at bootstrap time.

`syncPolicy.automated.selfHeal`/`prune` stay unconditional for every
generated `Application` (RFC #25 Decision 6: a merge to `main` moves every
cell once `stable` moves, with no separate "approve this sync" step by
design). Combined with a role mapped to `ADMIN`, that is full write access
to everything this one `AppProject` allows - the namespaces, chart
registries and resource kinds above, narrower than the IAM role's own
`AmazonEKSClusterAdminPolicy` grant but still enough to create a
`ClusterRoleBinding` and a `Deployment` in `kube-system`, which is itself
cluster-admin-equivalent in practice, not a narrow grant. The
compensating controls until #22's per-team projects exist are: this
namespace/registry/kind scoping, mapping a group to `ADMIN` only when it should
have that access (the `argocd` variable's own description), and closing
[#53](https://github.com/littlemex/distai-platform/issues/53) (`main`'s
branch ruleset requires no review and no passing check today, so the one
human checkpoint on the path from "a commit lands" to "it runs with this
access" does not yet exist either).

## NetworkPolicy defaults

Every cell already enforces `NetworkPolicy` (`infra/foundation`'s VPC CNI
`enableNetworkPolicy: "true"`), but enforcement with no policy objects is
not segmentation: with nothing shipped, any Pod anywhere can reach any
other Pod. An independent security-axis review pass (#63, filed as a
private report "SA4") found exactly that true of this platform's own
add-ons: `karpenter`/`kueue` (the only NetworkPolicy enforcement this
platform turned on, with no policy object anywhere to make it mean
anything) and `dcgm-exporter` (#46 - its `NetworkPolicy` existed but its
`allowedPeers` matched every namespace, the only real segmentation this
stack shipped until this PR).

The policy going forward: **default deny, name the exception**. An
add-on that exposes a network port ships `networkPolicy.enabled: true`
(or, if its own chart has no such toggle, a small companion `dir:`-based
`Application` of its own - `kueue-netpol`, `karpenter-netpol`) with no
peer allowed in by default; a cell (or a later PR, once a real consumer
exists) adds exactly the peer that component needs, never a blanket
`namespaceSelector: {}`/`podSelector: {}` "every pod" default.
`dcgm-exporter`'s own `allowedPeers: []` (renders `ingress: []` -
confirmed against the rendered manifest) was the first add-on to follow
this: a functional no-op (nothing scrapes it yet) and a real boundary
the day something does, since `dcgm-exporter.networkPolicy.allowedPeers`
is a cell-overridable key for exactly that.

`karpenter-netpol` and `kueue-netpol` follow the one pattern researched
for this exact problem: kube-apiserver's calls to a webhook or
aggregated-API port, and kubelet's own health-probe calls, cannot be
matched by a `podSelector`/`namespaceSelector` the way an ordinary Pod
can - the control plane and a node's own kubelet are not addressable
that way under VPC CNI. Rather than invent a workaround, both charts
copy the one already-shipped, already-documented answer to this problem:
upstream Kueue's own Kustomize `NetworkPolicy` component
(`kubernetes-sigs/kueue`, `config/components/networkpolicy/
manager-ingress.yaml`) scopes exactly these ports by port number alone,
with no `from:` peer at all, and says why in its own comment ("the
apiserver runs on the host network, so its source address cannot be
expressed as a pod or namespace selector"). Both charts open only the
ports this platform's own pinned chart versions actually need reachable
(Kueue 0.20.6: webhook `9443`, visibility API `8082`, probe `8081`;
Karpenter 1.15.2: probe `8081` only - this version ships no webhook
server at all, confirmed by rendering it) and deny everything else,
including each one's own metrics port, which nothing in a cell scrapes
yet.

What this still does not cover: a true network-level restriction on
*which* caller reaches those ports (only that the port itself, not the
whole Pod, is reachable) needs the EKS cluster security group, not
NetworkPolicy - AWS's own documented mechanism for control-plane-to-pod
traffic (`docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html`);
NetworkPolicy's own peer selectors cannot express "the control plane" at
all. RFC #22's own admin-owned default-deny baseline (Decision 6) is the
longer-term, cell-wide mechanism this per-add-on convention is a
stand-in for until it ships.

## Ordering

Argo CD's own kind-ordering (CRDs before CRs) handles ordering **inside**
one `Application`. Ordering **between** the `Application`s one
`ApplicationSet` generates is `RollingSync` (ApplicationSet Progressive
Syncs, Beta since Argo CD v3.3.0) when available; confirmed on a real
cluster (`gitops/tests/1.e2e.sh`, reading `platform.ApplicationSet`'s own
`status.applicationStatus`), the managed capability does **not** expose
it as of this PR - `status.applicationStatus` is empty, so every
`Application` instead syncs independently with `automated.selfHeal`, and
a later step's `Application` fails once and retries until an earlier one
it depends on converges. Either way, ordering *between*
`platform.ApplicationSet` and `cells.ApplicationSet` is always retry-based
convergence, never a `RollingSync` guarantee: `RollingSync` cannot span two
separate `ApplicationSet` objects.

| `ApplicationSet` | Step (`wave`) | Delivered in this PR |
| --- | --- | --- |
| `platform` | `crds` (`karpenter-crd`, `jobset-crd`) | yes |
| `platform` | `controllers` (`karpenter`, `kueue`, `optional-pool`, `vigil-controller`) | yes |
| `platform` | `accelerators` (`accel-nvidia-device-plugin`, `accel-nvidia-dra`, `accel-neuron-device-plugin`, `accel-neuron-dra`, `accel-device-classes`, `accel-efa-device-plugin-nvidia`, `accel-efa-device-plugin-neuron`) | yes |
| `platform` | `extras` | no - [#23](https://github.com/littlemex/distai-platform/issues/23) ([#18](https://github.com/littlemex/distai-platform/issues/18) does not use this wave at all: sharedfs is platform-optional, not core - see the `addons-optional`/`cells` rows below) |
| `cells` | `capacity` (`capacity-pool/*`, `smoke/*`) | yes |
| `cells` | `sharedfs` (`sharedfs/*` -> `gitops/charts/sharedfs-shares`: the static PersistentVolume, its reserving PVC and the `checkpoints`/`datasets` `FilesystemShare` objects) | yes ([#18](https://github.com/littlemex/distai-platform/issues/18)) |
| `cells` | `teams` | no - [#22](https://github.com/littlemex/distai-platform/issues/22) |
| `addons-optional` | `optional-1`..`optional-4` (`cells/*/addons/*`; catalog entries `dcgm-exporter`, `jobset`, `sharedfs` - a `jobset`/`sharedfs` marker uses `optional-1`, since each one's own real dependency is either core (`jobset-crd`) or outside this mechanism entirely (`sharedfs`'s own aws-fsx-csi-driver EKS managed add-on, `infra/foundation`'s, not a `gitops/addons/`/`gitops/addon-catalog/` entry) and needs no earlier optional wave) | yes ([#41](https://github.com/littlemex/distai-platform/issues/41), [#34](https://github.com/littlemex/distai-platform/issues/34), [#18](https://github.com/littlemex/distai-platform/issues/18)) |

## Versioning

Every chart is pinned to an exact version in its own `addon.yaml`
(`chart`, `repoURL`, `version`) - a platform add-on `Application`
(`karpenter`, `karpenter-crd`, `kueue`) is sourced from its own upstream
chart registry at that pinned version, never from this platform
repository, so it is never pinned to `stable`. The platform repository's
own Git ref that the root Application and every `cells`-generated
`Application` (sourced from this repository, never an upstream registry)
are pinned to is instead the moving tag `stable`, re-pointed only by
`.github/workflows/move-stable-tag.yml` immediately after a merge to
`main` (never by a pull request - RFC #25 Decision 6). A chart version
bump needs no re-run of `bootstrap.sh`: a cell picks it up once `stable`
moves and Argo CD next polls. A PR adding a *new chart registry*
(an `addon.yaml` whose `repoURL` no existing `addon.yaml` already uses)
does need one: the `platform` `AppProject`'s `sourceRepos` is computed by
`bootstrap.sh` from this checkout's own `gitops/addons/*/addon.yaml` every
run, never hand-maintained, so the re-run is what picks up the new
registry.

A PR bumping `addons/karpenter/addon.yaml`'s version must bump
`addons/karpenter-crd/addon.yaml` to match, and vice versa: both ship the
same five Karpenter CRDs (one as plain templates, one in a `crds/` folder
skipped via `helm.skipCrds`), and a mismatched pair is exactly what the
upgrade e2e's version-pair check exists to catch.

Current pins, confirmed against each chart's own OCI manifest on
2026-11-19 (see each `addon.yaml` for the full citation and content
digest - recorded for audit, since Argo CD's `Application` CRD has no
field to pin an OCI Helm chart by digest, only by `targetRevision`
semver):

| Add-on | Chart | Version |
| --- | --- | --- |
| `karpenter-crd` | `oci://public.ecr.aws/karpenter/karpenter-crd` | `1.15.2` |
| `karpenter` | `oci://public.ecr.aws/karpenter/karpenter` | `1.15.2` |
| `kueue` | `oci://registry.k8s.io/kueue/charts/kueue` | `0.20.6` |
| `vigil-controller` | `vigil-controller` from `https://oss.nextdoor.com/vigil` (classic Helm repository) | `0.7.0` |

Accelerator add-on pins, confirmed against each chart's upstream source on
2026-11-19 ([#28](https://github.com/littlemex/distai-platform/issues/28),
Facts checked; no content digest is recorded for these yet):

| Add-on | Chart | Version |
| --- | --- | --- |
| `accel-nvidia-device-plugin` | `nvidia-device-plugin` from `https://nvidia.github.io/k8s-device-plugin` (classic Helm repository) | `0.20.2` |
| `accel-nvidia-dra` | `oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu` | `0.5.1` |
| `accel-neuron-device-plugin`, `accel-neuron-dra` | `oci://public.ecr.aws/neuron/neuron-helm-chart` (one chart, two releases with opposite toggles) | `1.11.2` |
| `accel-device-classes` | local chart `gitops/charts/accel-device-classes` | - |
| `accel-efa-device-plugin-nvidia`, `accel-efa-device-plugin-neuron` | `aws-efa-k8s-device-plugin` from `https://aws.github.io/eks-charts` (classic Helm repository; one chart, two releases - its own `affinity` is not values-driven, so a single release cannot OR the two vendor method labels, see the add-on's own comment) | `v0.5.35` |

## Accelerators

A `NodePool` opts its nodes into exactly one advertiser per device class by
setting a method label through `capacity-pool`'s
`accelerator.methodLabel.key`/`.value`
([#19](https://github.com/littlemex/distai-platform/issues/19) Decision 2;
the value's own shape is [#17](https://github.com/littlemex/distai-platform/issues/17)'s):

| Label | Value | Advertiser selected |
| --- | --- | --- |
| `distai.dev/nvidia-gpu-method` | `device-plugin` | `accel-nvidia-device-plugin` |
| `distai.dev/nvidia-gpu-method` | `dra` | `accel-nvidia-dra` |
| `distai.dev/neuron-method` | `device-plugin` | `accel-neuron-device-plugin` |
| `distai.dev/neuron-method` | `dra` | `accel-neuron-dra` |

A `NodePool` without a method label gets no advertiser, so every
advertiser is always delivered and costs nothing on a cell that does not
use it. `cells/dp-a19-gpu-r3/capacity-pool/gpu.yaml` and
`cells/dp-a19-trn-r3/capacity-pool/trn.yaml` are the device-plugin-method
pools the light-tier e2e launches nodes from.

EFA has no vendor of its own (#19 Decision 4: "EFA | Same as the GPU on
the node"), so it does not add a sixth row to the table above:
`accel-efa-device-plugin-nvidia` selects
`distai.dev/nvidia-gpu-method=device-plugin` and
`accel-efa-device-plugin-neuron` selects
`distai.dev/neuron-method=device-plugin` - two releases of the one
upstream chart (its own `nodeAffinity` is hardcoded in the chart's
template, not values-driven, so a single release cannot OR the two
vendor labels; see the add-on's own comment) - **and both additionally
require `distai.dev/efa-attached=true`**, a second label
`capacity-pool` renders on a NodePool's node template only when
`pool.networkInterfaces`
([#50](https://github.com/littlemex/distai-platform/issues/50)) is
non-empty: the method label by itself says nothing about whether EFA
interfaces were ever configured, and confirmed on real hardware that
this chart's own Pod crash-loops, not merely reports zero, on a
method-labeled node with none (see "Known limits"). Real hardware
(`p4d.24xlarge`, two nodes, `NET/Libfabric`/GDRDMA `all_reduce_perf`) is
in this PR's own Test Results.

## Node readiness (startupTaints)

A freshly launched Karpenter node reaches `Ready: True` as soon as kubelet
registers it, before its own accelerator device-plugin DaemonSet (or any
future CSI driver) has advertised anything. A pool opts out of the race by
setting `capacity-pool`'s `pool.startupTaints` to the one key/effect
`vigil-controller` (below) is configured to watch -
`check_startup_taint_keys.py` fails the static checks if the two ever
disagree:

```yaml
pool:
  startupTaints:
    - key: distai.dev/startup-not-ready
      effect: NoSchedule
```

A plain `NodePool.spec.template.spec.startupTaints` entry, never mirrored
as a `ResourceFlavor` toleration the way `accelerator.taint`/
`tenancy.teamTaint` are (it is a node-readiness gate every Pod eventually
tolerates, not a tenancy or accelerator-class scheduling boundary).
`vigil-controller`, delivered in the
`controllers` step, watches for that key, works out which DaemonSets a node
is actually expected to run (the same scheduling predicates kube-scheduler
itself uses, so adding a new accelerator add-on needs no change to this
controller), waits for their Pods to go `Ready`, then removes the taint -
or removes it anyway after `timeoutSeconds` if one never comes up, so a
stuck DaemonSet degrades back to today's unprotected behavior rather than
wedging the node forever.

`vigil-controller`'s own placement in the `controllers` step (ahead of
`accelerators`/`capacity`) is this platform's own operational intent, not
an enforced dependency the way `karpenter-crd`'s CRDs are for `karpenter`:
"Ordering" above quotes the real mechanism -- `platform.ApplicationSet.yaml`'s
own `RollingSync` strategy is configured but not actually exposed by the
managed capability, so every Application "syncs independently with
`automated.selfHeal`, and a later step's Application fails once and
retries until an earlier one it depends on converges." That retry only
engages for a real object-level dependency (`capacity`'s `ResourceFlavor`
needing `kueue`'s CRD, for example); `vigil-controller` creates no CRD and
no object any later-wave chart reads, so a cell can finish bootstrapping
with `vigil-controller` unhealthy and no startup taint ever removed, with
no ordering failure surfaced anywhere else.

Every DaemonSet a pool with `pool.startupTaints` set actually depends on
must tolerate `distai.dev/startup-not-ready` itself, or it can never become
`Ready` while the taint is present and `vigil-controller` only ever removes
it at the timeout: `accel-nvidia-device-plugin`, `accel-neuron-device-plugin`,
`accel-efa-device-plugin-nvidia` and `accel-efa-device-plugin-neuron` already
do (their own `addon.yaml`). The NVIDIA/Neuron DRA advertisers
(`accel-nvidia-dra`, `accel-neuron-dra`) do not yet, deliberately: #19's own
E2/E4c found a dynamically provisioned DRA pool never initializes at all, and
a static NodePool for the DRA method is #27's own future scope, so there is
no real pool to opt into `pool.startupTaints` through that method today --
`check_startup_taint_keys.py` refuses the combination outright rather than
leaving it an unverified claim.

**What the gate actually guarantees, stated precisely:** `vigil-controller`
removes the taint once a DaemonSet's own Pod reports `Ready`, nothing more.
A DaemonSet whose readiness probe (or lack of one) says `Ready` before the
resource it advertises is actually usable -- for example a device-plugin
image that starts healthy but has not yet finished registering with kubelet
-- removes the race this issue describes, not a guarantee that every
resource the node is expected to provide is already live.

**If `vigil-controller` itself is down** (or a cell has not yet picked up
this PR through its own `bootstrap.sh` re-run, see "Versioning" above), no
startup-tainted node it should have watched is ever untainted automatically.
Confirm with `kubectl get node <node> -o jsonpath='{.spec.taints}'`, and
recover by hand once the real cause is fixed: `kubectl taint node <node>
distai.dev/startup-not-ready-` removes exactly the one taint this mechanism
owns, the same no-op-if-absent `-`-suffix syntax a day-to-day operator
already uses for any other taint.

## Adding a cell

1. Build the cell with `infra/foundation` and run `gitops/bootstrap/bootstrap.sh`
   against it (above). This alone delivers `karpenter-crd`, `karpenter`,
   `kueue` cluster-wide, and `optional-pool` (RFC #41 Decision 1: a core
   add-on, delivered to every cell) - the one `NodePool`/`EC2NodeClass`
   pair that exists before any `cells/<cluster-name>/capacity-pool/*.yaml`
   file does, an untainted, on-demand CPU pool with no Kueue
   `ResourceFlavor` of its own. No *team* `NodePool` exists yet.
2. Copy `gitops/cells/example-cell/` to `gitops/cells/<cluster-name>/`,
   replacing `example-cell` with the cell's own `cluster_name` output.
3. In `capacity-pool/cpu.yaml`, keep or change `values.pool.name`; `dir`
   must stay `gitops/charts/capacity-pool`. `clusterName` and `nodeRole`
   are filled in from the Cluster generator and the registration Secret's
   own annotations - never set them by hand in this file.
4. In `smoke/queue.yaml`, set `values.clusterQueue.resourceFlavor` to the
   same `pool.name` chosen in step 3.
5. For every file under `addons/` (today, just `dcgm-exporter.yaml`; a
   future catalog entry adds its own), decide whether to keep it -- each
   one opts this cell into one `platform-optional` component (RFC
   [#41](https://github.com/littlemex/distai-platform/issues/41)); a
   platform-optional component's own definition is that the cell works
   the same either way.
6. Open a PR. Once merged and `stable` moves, `cells.ApplicationSet.yaml`
   picks the new cell's files up on its own - no second `bootstrap.sh` run
   is needed for an ordinary cell addition (only a new chart registry, or
   a `--revision` change ahead of a merge, needs one).

## Known limits (this PR)

- `gitops/charts/capacity-pool` declares one capacity type per release
  (`on-demand`, `reserved` selecting a Capacity Reservation by tag, or
  `flex`), so #17's `-rsv`/`-od`/`-flex` pools are separate releases; its
  `accelerator.methodLabel`/`accelerator.taint`/`tenancy.teamTaint` values
  render labels and taints but enforce nothing by themselves until #22
  ships (#19's own `accel-*` advertisers select nodes by
  `accelerator.methodLabel` and are delivered in the `accelerators` step
  below). Field-level detail is in
  [`charts/capacity-pool/README.md`](./charts/capacity-pool/README.md).
- No team object or notifications add-on ships here (RFC #25 Decision 9);
  their steps exist in the RFC but have no `addon.yaml` yet, so they
  generate nothing today. sharedfs (also named in that same Decision) now
  does ship - [#18](https://github.com/littlemex/distai-platform/issues/18),
  `gitops/addon-catalog/sharedfs` and `gitops/charts/sharedfs-shares`.
- The DRA method (`accel-nvidia-dra`, `accel-neuron-dra`) is delivered and
  statically checked, but no dynamically provisioned `NodePool` initializes
  a DRA node (#19 E2, E4c); a static `NodePool` for DRA is
  [#27](https://github.com/littlemex/distai-platform/issues/27)'s scope.
  Only the device-plugin method is verified on real nodes.
- The EFA **DRA** driver (`aws-dranet`, DeviceClass
  `efa.networking.k8s.aws`, driver `dra.net` - #19's own Upstream state
  table) is out of scope for both `accel-efa-device-plugin-nvidia` and
  `accel-efa-device-plugin-neuron`: these add-ons only ship the
  device-plugin method (`vpc.amazonaws.com/efa` as a Layer 1 extended
  resource), the same scope line #28 already drew between
  `accel-nvidia-device-plugin`/`accel-neuron-device-plugin` and their own
  `-dra` siblings. Pairing EFA's own DRA driver with the GPU/Neuron DRA
  method on the same node (#19's own alignment measurement: `pcieRoot`
  constraints, 45.8 vs 3.6-4.7 GB/s) is left to a follow-up issue; nothing
  in either add-on's own nodeSelector shape blocks adding it later.
- Both EFA add-ons run at a **higher trust level than this platform's
  existing device-plugin add-ons** (checked against `accel-nvidia-device
  -plugin`, the one with the closest role -- not re-checked against the
  other three, which are not device-plugin DaemonSets with GPU-adjacent
  device access in the same way): `helm template`-ing
  `nvidia-device-plugin:0.20.2` with this platform's own pinned values
  renders the active `nvidia-device-plugin-ctr` container's own
  `securityContext` as `allowPrivilegeEscalation: false, capabilities:
  {drop: ["ALL"]}`, and no `hostNetwork` key anywhere in the output
  (confirmed by rendering the exact chart and values, not by reading
  `podSecurityContext`, a different, pod-level field that says nothing
  about the container). `aws-efa-k8s-device-plugin:v0.5.35`'s template
  sets `hostNetwork: true` with no `{{- if }}` guard at all -- no values
  key can turn it off without forking the chart, and that is not
  attempted here. Its `securityContext`, by contrast, **is** read from
  `.Values.securityContext` (`{{- toYaml .Values.securityContext |
  nindent 12}}`, confirmed in the template) and so is overridable; the
  chart's own default for that value is `privileged: true,
  allowPrivilegeEscalation: true, runAsUser: 0`. Both add-ons override it
  to `privileged: false, allowPrivilegeEscalation: false, capabilities:
  {drop: ["ALL"]}` (`runAsUser` stays `0` -- the chart's own image opens
  `/dev/infiniband` and the kubelet device-plugin socket as root, and no
  rebuilt image is carried here to change that). This is not a guess: the
  override was rolled out over the chart's own privileged default on a
  live `p4d.24xlarge` node and `allocatable.vpc.amazonaws.com/efa` still
  read `4` before and after, confirmed back to back on the identical node
  (review round 1, finding B1; not yet separately confirmed on
  a Neuron+EFA node, since EFA device enumeration does not itself depend
  on the GPU/Neuron driver but no `trn2`-class hardware was available in
  this PR's own real-machine run). `gitops/tests/check_pinned_crds.py`
  now asserts this exact override reaches the exact pinned chart's own
  rendered container, keyed by addon name rather than read back from
  `addon.yaml`'s own values -- confirmed, with a deliberately-broken copy
  during this check's own development, to actually fail if the override
  is weakened or dropped (review round 2, finding N6). The
  reduced-privilege confirmation above was on Amazon Linux 2023, the
  only AMI family `gitops/charts/capacity-pool` uses today
  (`values.yaml`'s own `amiFamily: AL2023`, no Bottlerocket pool exists
  in this platform) -- a SELinux-enforcing host (Bottlerocket's own
  default) could plausibly deny an unprivileged container the kubelet
  device-plugin socket's `hostPath` differently than AL2023 does (review
  round 2, finding N7); not a gap in this PR until this
  platform actually has a Bottlerocket pool to check it against.
  If the override is ever lost anyway (the chart bumps and renames the
  key, or a future PR removes it without that static check catching it
  first), the chart's own `privileged: true` plus `runAsUser: 0` default
  returns, which is effectively root on the node -- `privileged: true`
  grants the host's own filesystem and device nodes directly (not
  through the `/var/lib/kubelet/device-plugins` socket this chart
  mounts for its own, narrower purpose: registering the extended
  resource with kubelet, nothing else), which on a Kubernetes node
  includes every co-located Pod's own service account token on disk,
  not only this one Pod's intended `/dev/infiniband` access (corrected,
  review round 3: an earlier draft of this sentence named the
  device-plugin socket itself as the path to other Pods' tokens, which
  it is not -- that socket only carries device-plugin registration
  traffic).
  The risk the remaining, non-overridable half carries today regardless:
  `hostNetwork: true` means a Pod is not behind the extra network hop the
  foundation's own IMDSv2 hop-limit-of-1 (#20, Facts checked) is meant to
  stop -- `kubectl exec` into either release's Pod reaches
  `http://169.254.169.254` on the node's own network namespace exactly
  like any other process on that node, which can mean the node's own
  `karpenter-node` IAM role credentials, even with `privileged: false`.
  Who can reach this is Kubernetes RBAC and EKS access entries (the
  foundation's own `admin_principal_arns`, #20), **not** Argo CD
  `AppProject` destinations -- an earlier draft of this note cited "no
  team `AppProject` targets `kube-system`" as the control, which is the
  wrong layer: `AppProject` governs where Argo CD *deploys*, not who
  holds `pods/exec` once a Pod exists. Editing either add-on's own
  `values:` is the other way in; checked directly against the live
  repository rather than assumed, 2026-11-22: a ruleset on `main`
  (`protect-main`) requires every change to go through a pull request
  (no direct push, no force-push, no deletion), but that ruleset's own
  `require_code_owner_review` is `false` and `required_approving_review_
  count` is `0` -- `.github/CODEOWNERS`' own comment ("Enforcement comes
  from the branch ruleset on main, not from this file") is **not**
  currently true: a PR against this file can be merged with zero
  reviews. This is a real, repo-wide gap (not scoped to this PR, and not
  one this PR's own `gh`-token permissions -- Contents/Issues/Pull
  requests only, no Administration -- can fix), named here rather than
  assumed closed because an earlier draft of this note cited it as a
  control.
  This add-on does not change who can reach `kube-system` today; it is a
  real increase in what that access is worth once held, and is recorded
  here rather than left for a reader to discover by diffing chart
  templates themselves.
- **A method label alone is not enough to select this add-on's own Pod
  -- fixed in this PR, after being confirmed as a real regression on
  real hardware, not shipped as a documented risk.** The method label
  alone (#19 Decision 2's own opt-in, the same as the four existing
  `accel-*` add-ons) says nothing about whether the pool carrying it
  ever configured `pool.networkInterfaces`; `gitops/cells/dp-a19-gpu-r3/
  capacity-pool/gpu.yaml` and `dp-a19-trn-r3/capacity-pool/trn.yaml`
  (#28's own existing light-tier fixtures) both carry the method label
  with `pool.networkInterfaces` unset, on an `instance-family` wide
  enough to resolve to an EFA-capable size -- for `dp-a19-trn-r3`
  specifically, *every* `trn2` size the pinned chart's own
  `supportedInstanceLabels` lists (`trn2.3xlarge`, `trn2.48xlarge`) is
  EFA-capable, so this was not an occasional risk for that fixture, it
  was certain. Confirmed on real hardware what actually happens there,
  not assumed: after three real-machine attempts on an EFA-capable GPU
  instance type (`g6e.12xlarge`, then `g5.12xlarge`) each hit EC2
  capacity errors before a node could be reached (confirmed read-only
  afterward not to be the same pricing-data gap `trn2.3xlarge` has --
  both instance types are offered with a published on-demand price,
  just no capacity at the time), a cheap EFA-capable CPU-only instance
  type (`c5n.9xlarge`, no GPU needed, far more available) got a real
  node: this chart's own Pod does not simply report `efa=0` there, it
  crash-loops (`phase: Completed`, never `Running`, `restartCount`
  climbing `0 -> 2 -> 3 -> 4 -> 5` over about 3 minutes). This does not
  break GPU/Neuron workloads on the node (the accelerator's own device
  plugin is a separate DaemonSet), but it does leave the `accelerators`
  step unhealthy on both of this platform's own existing fixtures,
  every time Karpenter happens to resolve `dp-a19-gpu-r3` to an
  EFA-capable size and *always* for `dp-a19-trn-r3` -- a real regression
  this PR would otherwise have introduced on pools that work today.
  The fix: `gitops/charts/capacity-pool`'s own `templates/nodepool.yaml`
  now renders `distai.dev/efa-attached: "true"` on a NodePool's node
  template only when at least one `pool.networkInterfaces` entry has
  `interfaceType: efa-only` (#63, filed as #59 - stated here too loosely
  before: a pool whose `networkInterfaces` lists only the primary
  `interface` entry, required by Karpenter's own CEL validation whenever
  the list is non-empty at all, is non-empty but attaches zero EFA
  devices, so "non-empty" alone was not the actual signal; never
  derived from the method label or the instance type either, both of
  which a pool can carry without ever requesting an EFA interface), and both
  `accel-efa-device-plugin-*` releases AND it into their own
  `nodeSelector` alongside the vendor method label. Confirmed by `helm
  template`: neither existing fixture renders the new label (since
  neither sets `pool.networkInterfaces`, so neither ever receives this
  Pod at all now), while this PR's own real `p4d.24xlarge` test values
  (which do set it) do render it. `gitops/tests/check_pinned_crds.py`
  asserts the AND reaches the rendered DaemonSet for both releases, the
  same silent-Helm-value risk its own method-label check already
  guards against (confirmed to actually fail with a deliberately-broken
  copy). This one field addition to `capacity-pool` is the one part of
  this PR that reaches outside `gitops/addons/accel-efa-device-plugin-*`
  -- `#17` otherwise owns this chart's shape, the same boundary #28/PR
  #40 already drew, crossed here only because the regression this field
  closes is this PR's own to fix, not a new capability added on `#17`'s
  behalf; no existing consumer of `pool.networkInterfaces` or
  `accelerator.methodLabel` changes behavior (the new label is purely
  additive, gated on a field every current fixture leaves unset).
- Both EFA add-ons' pinned image stays at the chart's own
  default Region (`us-west-2`), never overridden per cell: see the
  add-on's own `addon.yaml` comment for why (the platform's own
  `valuesFrom` mechanism substitutes a whole parameter value, never
  concatenates one into a larger string, and the registry host embeds the
  Region in the middle of the string). The identical-digest check across
  three Regions (`us-west-2`, `us-east-1`, `ap-northeast-1`) only shows
  the *content* is Region-independent; it says nothing about whether a
  given cell's own network path can reach `us-west-2`'s ECR endpoint.
  This PR's own real-machine run pulled it successfully from
  `ap-northeast-1` because `infra/foundation`'s default cell has a NAT
  gateway (internet egress); a cell built with ECR reachable only through
  Regional VPC endpoints and no NAT would not reach a different Region's
  endpoint and would see `ImagePullBackOff` on every node this add-on
  matches. Every cell's own EFA advertisement depends on `us-west-2`
  reachability at each node's cold start until a per-Region override
  exists -- a known condition, not only a deferred optimization.
- `platform.ApplicationSet.yaml` and `cells.ApplicationSet.yaml`'s
  `goTemplate: true` plus `templatePatch` mechanism (Decision 2) is this
  PR's own construction, not a primary-sourced example from Argo CD's
  docs; Experiment 1's real-cluster verification is what this PR's own
  `gitops/tests/1.e2e.sh` now provides (every generated Application
  reaching `Synced`, `karpenter`/`kueue` also reaching `Healthy` -
  `karpenter-crd` ships only `CustomResourceDefinition` objects, with no
  `Health` status of its own; the OCI chart and the cross-generator
  `revision:` templating are both evidenced too), not an open item.
