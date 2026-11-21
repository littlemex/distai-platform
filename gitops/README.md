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
private report "SA4") found exactly that true of `karpenter`/`kueue` -
the only NetworkPolicy enforcement this platform turned on, with no
policy object anywhere to make it mean anything.

The policy going forward: **default deny, name the exception**. An
add-on that exposes a network port ships `networkPolicy.enabled: true`
(or, if its own chart has no such toggle, a small companion `dir:`-based
`Application` of its own - `kueue-netpol`, `karpenter-netpol`) with no
peer allowed in by default; a cell (or a later PR, once a real consumer
exists) adds exactly the peer that component needs, never a blanket
`namespaceSelector: {}`/`podSelector: {}` "every pod" default.

`karpenter-netpol` and `kueue-netpol` (this PR) follow the one pattern
researched for this exact problem: kube-apiserver's calls to a webhook
or aggregated-API port, and kubelet's own health-probe calls, cannot be
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
| `platform` | `crds` (`karpenter-crd`) | yes |
| `platform` | `controllers` (`karpenter`, `kueue`, `optional-pool`) | yes |
| `platform` | `accelerators` | no - [#19](https://github.com/littlemex/distai-platform/issues/19) |
| `platform` | `extras` | no - [#18](https://github.com/littlemex/distai-platform/issues/18)/[#23](https://github.com/littlemex/distai-platform/issues/23) |
| `cells` | `capacity` (`capacity-pool/*`, `smoke/*`) | yes |
| `cells` | `teams` | no - [#22](https://github.com/littlemex/distai-platform/issues/22) |
| `addons-optional` | `optional-1`..`optional-4` (`cells/*/addons/*`) | yes ([#41](https://github.com/littlemex/distai-platform/issues/41)) |

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

- CPU-only: `gitops/charts/capacity-pool` ships one capacity type, no
  reserved/on-demand/flex ordering across several `NodePool`s
  ([#17](https://github.com/littlemex/distai-platform/issues/17) extends
  it).
- No accelerator advertiser, team object, `sharedfs` or notifications
  add-on ships here (RFC #25 Decision 9); their steps exist in the RFC but
  have no `addon.yaml` yet, so they generate nothing today.
- `platform.ApplicationSet.yaml` and `cells.ApplicationSet.yaml`'s
  `goTemplate: true` plus `templatePatch` mechanism (Decision 2) is this
  PR's own construction, not a primary-sourced example from Argo CD's
  docs; Experiment 1's real-cluster verification is what this PR's own
  `gitops/tests/1.e2e.sh` now provides (every generated Application
  reaching `Synced`, `karpenter`/`kueue` also reaching `Healthy` -
  `karpenter-crd` ships only `CustomResourceDefinition` objects, with no
  `Health` status of its own; the OCI chart and the cross-generator
  `revision:` templating are both evidenced too), not an open item.
