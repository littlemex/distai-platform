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
    cells.ApplicationSet.yaml    # one Application per gitops/cells/<cell>/{capacity-pool,smoke}/*.yaml
  addons/
    <name>/addon.yaml            # one platform-wide add-on: chart, version, wave, values
  charts/
    <name>/                      # shared chart templates, parameterized per cell
  cells/
    <cluster-name>/
      capacity-pool/*.yaml        # one parameter file per NodePool
      smoke/*.yaml                 # the admin-owned smoke ClusterQueue/LocalQueue
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
root `Application` delivers `platform.ApplicationSet.yaml` and
`cells.ApplicationSet.yaml`, which deliver every add-on and every cell's
own capacity.

The script is idempotent: re-running it with the same inputs changes
nothing. It aborts before writing anything if the live `kubectl` context's
cluster does not match `--tf-outputs`, or if a `cell-registration` Secret
already exists naming a *different* cluster - it never overwrites another
cell's registration under the same name.

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
| `platform` | `crds` (`karpenter-crd`) | yes |
| `platform` | `controllers` (`karpenter`, `kueue`) | yes |
| `platform` | `accelerators` (`accel-nvidia-device-plugin`, `accel-nvidia-dra`, `accel-neuron-device-plugin`, `accel-neuron-dra`, `accel-device-classes`, `accel-efa-device-plugin-nvidia`, `accel-efa-device-plugin-neuron`) | yes |
| `platform` | `extras` | no - [#18](https://github.com/littlemex/distai-platform/issues/18)/[#23](https://github.com/littlemex/distai-platform/issues/23) |
| `cells` | `capacity` (`capacity-pool/*`, `smoke/*`) | yes |
| `cells` | `teams` | no - [#22](https://github.com/littlemex/distai-platform/issues/22) |

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
vendor labels; see the add-on's own comment) - and each advertises
`vpc.amazonaws.com/efa` on whichever of those nodes also has EFA network
interfaces attached
(`pool.networkInterfaces`, [#50](https://github.com/littlemex/distai-platform/issues/50)).
Real hardware (`p4d.24xlarge`, two nodes, `NET/Libfabric`/GDRDMA
`all_reduce_perf`) is in this PR's own Test Results.

## Adding a cell

1. Build the cell with `infra/foundation` and run `gitops/bootstrap/bootstrap.sh`
   against it (above). This alone delivers `karpenter-crd`, `karpenter` and
   `kueue` cluster-wide - no `NodePool` exists yet.
2. Copy `gitops/cells/example-cell/` to `gitops/cells/<cluster-name>/`,
   replacing `example-cell` with the cell's own `cluster_name` output.
3. In `capacity-pool/cpu.yaml`, keep or change `values.pool.name`; `dir`
   must stay `gitops/charts/capacity-pool`. `clusterName` and `nodeRole`
   are filled in from the Cluster generator and the registration Secret's
   own annotations - never set them by hand in this file.
4. In `smoke/queue.yaml`, set `values.clusterQueue.resourceFlavor` to the
   same `pool.name` chosen in step 3.
5. Open a PR. Once merged and `stable` moves, `cells.ApplicationSet.yaml`
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
- No team object, `sharedfs` or notifications add-on ships here (RFC #25
  Decision 9); their steps exist in the RFC but have no `addon.yaml` yet,
  so they generate nothing today.
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
  (Fable 5.2 review round 1, finding B1; not yet separately confirmed on
  a Neuron+EFA node, since EFA device enumeration does not itself depend
  on the GPU/Neuron driver but no `trn2`-class hardware was available in
  this PR's own real-machine run). `gitops/tests/check_pinned_crds.py`
  now asserts this exact override reaches the exact pinned chart's own
  rendered container, keyed by addon name rather than read back from
  `addon.yaml`'s own values -- confirmed, with a deliberately-broken copy
  during this check's own development, to actually fail if the override
  is weakened or dropped (Fable 5.2 review round 2, finding N6). The
  reduced-privilege confirmation above was on Amazon Linux 2023, the
  only AMI family `gitops/charts/capacity-pool` uses today
  (`values.yaml`'s own `amiFamily: AL2023`, no Bottlerocket pool exists
  in this platform) -- a SELinux-enforcing host (Bottlerocket's own
  default) could plausibly deny an unprivileged container the kubelet
  device-plugin socket's `hostPath` differently than AL2023 does (Fable
  5.2 review round 2, finding N7); not a gap in this PR until this
  platform actually has a Bottlerocket pool to check it against.
  If the override is ever lost anyway (the chart bumps and renames the
  key, or a future PR removes it without that static check catching it
  first), the chart's own `privileged: true` plus `runAsUser: 0` default
  returns, which is effectively root on the node -- host devices, the
  host filesystem, and (via the kubelet socket this chart itself mounts)
  every co-located Pod's own service account token, not only this one
  Pod's intended `/dev/infiniband` access.
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
- **A root, host-network Pod runs on more nodes than have EFA, and
  whether it merely reports zero or crash-loops there is not yet
  confirmed on real hardware.** Both add-ons select by method label
  alone (#19 Decision 2's own opt-in), the same as the four existing
  `accel-*` add-ons; neither additionally requires
  `pool.networkInterfaces` to be non-empty, because no label records
  that fact today (`capacity-pool`'s own `accelerator.methodLabel` and
  `pool.networkInterfaces` are independent fields, #17's own chart). A
  `g7`/`p4d` pool that opts into `nvidia-gpu-method=device-plugin`
  without configuring EFA interfaces still gets this one more Pod
  (`runAsUser: 0`, `hostNetwork: true` -- not `privileged`, now that
  Fable 5.2 review round 1's finding B1 is fixed), matching by instance
  type regardless of whether that specific pool happens to request
  interfaces -- a real, if narrow, widening of this trust level's own
  footprint beyond nodes that actually need it. Three real-machine
  attempts to confirm the Pod's own behaviour there (`Running` reporting
  `efa=0`, versus a crash loop) each hit EC2 capacity errors before a
  node with this add-on's Pod on it could be checked (`g6e.12xlarge` and
  `g5.12xlarge`, both `InsufficientCapacity`/`UnfulfillableCapacity` in
  `ap-northeast-1` at the time, confirmed read-only afterward: both
  instance types are offered in every AZ this platform's foundation
  uses and both have a published on-demand price, so this was not the
  same pricing-data gap `trn2.3xlarge` has -- just no capacity at the
  time) -- stopped after three failed attempts rather than retried
  further, so this remains an open question, not a confirmed "reports
  zero" claim. The fix for the footprint itself (a label `capacity-pool`
  itself sets only when `pool.networkInterfaces` is non-empty, ANDed
  into both add-ons' own `nodeSelector`) is `#17`'s chart to add, not
  this PR's -- recorded here as a named follow-up, not silently
  accepted.
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
