# Tests for the gitops/ delivery layer

Three scripts check `gitops/` against the acceptance criteria of
[issue #25](https://github.com/littlemex/distai-platform/issues/25) (the
delivery layer), scoped to its first PR (decision 9): bootstrap, the
`crds`/`controllers`/`capacity` steps, the CPU `capacity-pool` skeleton, the
admin smoke queue, and the upgrade e2e's version-pair check. No
accelerators (`#19`), no per-team objects (`#22`) and no `sharedfs`/
notifications (`#18`/`#23`) ship in this PR, so this layer's tests do not
check them either.

[Issue #41](https://github.com/littlemex/distai-platform/issues/41) adds
the tier model on top: a fourth core add-on (`optional-pool`), the
`gitops/addon-catalog/` directory, per-cell marker files under
`gitops/cells/<cell>/addons/`, and a third ApplicationSet,
`addons-optional.ApplicationSet.yaml`, with `dcgm-exporter` as the first
platform-optional entry. Two static checks (`check_addon_tiers.py`,
`check_addon_catalog_sync.py`) and `1.e2e.sh` step 15 cover it.

| Script | What it checks | Needs AWS | Duration |
| --- | --- | --- | --- |
| `0.static.sh` | Required files, `bash -n`/`shellcheck` on every `*.sh` under `gitops/` (including this suite's own three scripts, not only `bootstrap.sh`), `yamllint` on every literal (non-templated) tracked YAML file, the structural contract of every `addon.yaml`/cells parameter file and the three ApplicationSets (`check_gitops_contract.py`), the tier and naming rules of issue #41 Decision 2 (`check_addon_tiers.py`), issue #41 Decision 3's checks (0)-(4) of every `cells/*/addons/*.yaml` marker against its catalog entry, including each `overridableKeys` path against the wrapper chart's coalesced defaults (`check_addon_catalog_sync.py`), `helm lint`/`helm template` of `charts/capacity-pool`, `charts/smoke`, `charts/optional-pool` and `charts/dcgm-exporter` (after `helm dependency build`), `kubeconform` of the rendered output plus the three ApplicationSets and the root Application against pinned upstream + CRD-catalog schemas, and `check_pinned_crds.py` validating the rendered CRD-backed objects against each pinned chart's own exact CRD versions | No | About 2 to 3 minutes |
| `1.e2e.sh` | Builds one foundation cell (with a temporary Identity Center group), the before/after RBAC change on the capability's own access entry, bootstrap idempotency / `--revision`-only re-run / wrong-cluster abort, the `crds`→`controllers`→`capacity` ordering (including two deliberately broken steps), the OCI chart and Git-file-generator-revision checks, no shared CRD between `karpenter-crd` and `karpenter`, the admin smoke canary through Kueue and Karpenter, one accidental generator-entry loss, one full bootstrap-object teardown and re-adopt, the `dcgm-exporter` platform-optional add-then-remove cycle with a GPU placement check (issue #41), then destroy and leftovers | Yes | About 60 to 80 minutes |
| `2.upgrade.sh` | The mechanical version-pair check (decision 6) on a mismatched `karpenter`/`karpenter-crd` bump, then a matched bump against a live cell: no `Application` goes `Degraded`, the `NodePool`-launched instance is not replaced, and the canary pod stays `Running` throughout | Yes | About 35 to 50 minutes |

## Prerequisites

Everything in `infra/foundation/tests/README.md`'s prerequisites, plus:

- Helm `>= 3.8` (OCI charts), for `0.static.sh` only (`1.e2e.sh`/`2.upgrade.sh`
  never call `helm` themselves -- Argo CD installs every chart in-cluster).
- `uv` (for `0.static.sh`'s pinned `yamllint`/`pyyaml`, and for `2.upgrade.sh`'s
  own `check_gitops_contract.py` calls, pinned the same way), `curl`,
  `sha256sum` (for pinning `kubeconform` by checksum if it is not already on
  `PATH`) and `shellcheck` (required, not optional - `0.static.sh` fails
  closed if it is missing, rather than silently skipping that check).
- An IAM Identity Center instance in the test account/Region, and an IAM
  principal that can call `identitystore:CreateGroup`/`DeleteGroup`
  (`1.e2e.sh`/`2.upgrade.sh` create and delete their own temporary group;
  unlike `infra/foundation/tests/1.e2e.sh`, no pre-existing group ID is
  taken as input), `eks:ListAssociatedAccessPolicies`,
  `eks:DescribeCapability`, `eks:ListCapabilities`.
- A GitHub token with **Contents: write** on `littlemex/distai-platform`
  itself (`GITOPS_TEST_REPO_URL` defaults to it, and every manifest this
  suite bootstraps - both `ApplicationSet`s, the root Application,
  `bootstrap.sh`'s own `platform` `AppProject` - hard-codes that same
  repository URL as its Git source, so pointing `GITOPS_TEST_REPO_URL` at
  a fork does not actually make Argo CD read the fork's branches; there
  is no supported way to run this suite against a fork today). This
  token can move the `stable` tag (nothing scopes it to `refs/heads/e2e/*`
  branches), which every cell's own root Application and every
  `cells`-generated Application are pinned to - until a maintainer
  configures the tag-protection ruleset Decision 6's Residual risks
  names, holding this token is equivalent to cluster-admin on every cell
  tracking `stable`. Read fresh from AWS SSM Parameter Store (SecureString) at
  `GITOPS_TEST_TOKEN_SSM_PARAM` (a parameter you create; the default,
  `/relay/github/distai-platform`, is only this environment's own naming
  convention, not a requirement) in `GITOPS_TEST_TOKEN_SSM_REGION`
  (default `us-east-1`) -- never passed as an env var, a command-line
  argument, or written to `.git/config`: both scripts read it through a
  one-shot `GIT_ASKPASS` helper, deleted immediately after the one `git`
  command that needs it. `1.e2e.sh` pushes up to seven small, disposable
  branches (one per-run cell fixture if `NAME` needs one, `pristine-both-broken`
  and `pristine-kueue-broken` for the pristine first-bootstrap stages,
  `break-crds`, `break-kueue`, `remove-kueue`, and one of
  `no-dcgm-exporter`/`add-dcgm-exporter` for step 15); `2.upgrade.sh` pushes up
  to two (the cell fixture, `upgrade-match`). Every one of them lives under
  `refs/heads/e2e/<run-id>/*` (a guard function refuses pushing or
  deleting anything outside that namespace), to exercise the ordering,
  generator-loss and upgrade experiments on a real Argo CD sync; `main`
  and `stable` are never touched. Each run also lists every remote
  `e2e/*` branch older than a day at its own start (reported, for a human
  to clean up) and deletes the ones already in its own `e2e/<run-id>/*`
  namespace. Branches are deleted again when the run ends, on success and
  on failure alike. This token is not optional: the pristine stage A/B/C
  sequence (two disposable branches, `pristine-both-broken`/
  `pristine-kueue-broken`), this cell's own first-ever bootstrap, pushes
  unconditionally, same as `2.upgrade.sh` and `1.e2e.sh`'s own step 13
  generator-entry-loss experiment (`remove-kueue`), since the write is
  exactly what their own acceptance criteria need; `GITOPS_SKIP_ORDERING_EXPERIMENT=1`
  on `1.e2e.sh` skips only step 12's own two further disposable branches
  (`break-crds`/`break-kueue`, its already-converged-cell re-confirmation
  of the same criterion), not the token requirement itself.
- For `2.upgrade.sh`: a real, currently published Karpenter version
  different from `addons/karpenter/addon.yaml`'s pinned one (confirm with
  `helm show chart oci://public.ecr.aws/karpenter/karpenter --version <x>`);
  this test does not guess a "next" version, since nothing here can assume
  upstream's release cadence.

## Running these tests

Run from a machine with the AWS CLI v2, `kubectl`, `git` and `python3` on
`PATH`, and credentials for the account/Region under test (see
`infra/foundation/tests/README.md`'s own prerequisites for the IAM calls
needed). `0.static.sh` needs no AWS credentials at all:

```bash
cd gitops/tests
./0.static.sh
```

For `1.e2e.sh`/`2.upgrade.sh`, export the same variables
`infra/foundation/tests/README.md`'s "End-to-end test" section documents
(`AWS_REGION`, `NAME`, `STATE_BUCKET`, `STATE_REGION`,
`ADMIN_PRINCIPAL_ARN`, `MY_CIDR`), plus this layer's own. **`NAME` can be
anything** (pick one no other concurrent run on this account/Region is
using -- it is also the Terraform state key and the Identity Center group
display name, so two runs sharing one `NAME` collide on the state lock):
`cells.ApplicationSet.yaml`'s Git file generator reads
`gitops/cells/{{ .name }}/capacity-pool/*.yaml` and `.../smoke/*.yaml`
from the checked-in repository itself, and decision 9 ships exactly one
such pair, under `gitops/cells/example-cell/` (matching
`infra/foundation/README.md`'s own `NAME=example-cell` convention) -- a
`NAME` with no matching directory would otherwise leave the
`capacity`/smoke step generating nothing at all (confirmed on a real
cluster before this was fixed: "no Application named
`<NAME>-capacity-pool-<pool>` appeared"). Both scripts now close this gap
themselves, before touching any AWS resource: if `GITOPS_REVISION` has no
`gitops/cells/${NAME}/` directory, each clones `GITOPS_REVISION`, copies
`gitops/cells/example-cell/` to `gitops/cells/${NAME}/` unchanged, pushes
the result to this run's own disposable branch
(`refs/heads/e2e/<run-id>/cell-<NAME>`, deleted again in `cleanup()` like
every other disposable branch here), and bootstraps from that branch
instead of the literal `GITOPS_REVISION` for the rest of the run. `NAME`
and `example-cell` collide with nothing: a run with `NAME=example-cell`
finds the checked-in directory already there and creates no branch at
all.

```bash
export AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_REGION="<region with an IAM Identity Center instance>"
export NAME="<cell name unused by any other cell in this account, any region>"
export STATE_BUCKET="<your Terraform state bucket>"
export STATE_REGION="<region of that bucket>"
export ADMIN_PRINCIPAL_ARN="<the principal running this test>"
export MY_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
export GITOPS_REVISION="<this PR's branch, already pushed to GitHub>"
export GITOPS_BASE_REF="<a ref of infra/foundation before issue #25's access-policy-association change>"
export ARGOCD_IDC_INSTANCE_ARN="<arn:aws:sso:::instance/ssoins-...>"
export ARGOCD_IDC_REGION="<region of the Identity Center instance>"
export ARGOCD_IDC_IDENTITY_STORE_ID="$(aws sso-admin describe-instance \
  --instance-arn "${ARGOCD_IDC_INSTANCE_ARN}" --region "${ARGOCD_IDC_REGION}" --query IdentityStoreId --output text)"
cd gitops/tests
./1.e2e.sh 2>&1 | tee "/tmp/gitops-e2e-$(date +%Y%m%d%H%M%S).log"
```

For `2.upgrade.sh` instead, additionally export `UPGRADE_TO_KARPENTER_VERSION` (a real, published Karpenter version different from `addons/karpenter/addon.yaml`'s pinned one) and run `./2.upgrade.sh` in place of `./1.e2e.sh` above.

## Acceptance criteria -> checks

| Acceptance criterion (issue #25) | Checked by |
| --- | --- |
| OCI chart reference accepted; Git-file-generator `revision:` resolves from the same Matrix's Cluster generator | `1.e2e.sh` step 9 (`${APP_KARPENTER}` Healthy+Synced from an `oci://` source; `${APP_CAPACITY_POOL}`'s `targetRevision` -- the `cells` ApplicationSet's own Git-file-generator `revision:` field, resolved from the Cluster generator's annotation -- matches the Secret's annotation; `${APP_KARPENTER}`'s own `targetRevision` is its pinned chart version, never a git revision, so it cannot be the check for this criterion) |
| Before this PR's foundation change: no `AmazonEKSClusterAdminPolicy` association on the capability's access entry (it already carries the two built-in Argo-CD-capability-management policies); after: `AmazonEKSClusterAdminPolicy` added | `1.e2e.sh` steps 2-3 (same cell, `GITOPS_BASE_REF` then this checkout's `infra/foundation`) |
| bootstrap.sh idempotent; `--revision`-only re-run updates the Secret annotation and root `Application`'s `targetRevision` together; wrong-cluster attempt aborts before any write | `1.e2e.sh` steps 5-7 (a `.spec`/annotation write-fingerprint, not a raw `resourceVersion`, compared before/after each re-run; step 7's 7a and 7b each forge one of decision 1's two fields independently) |
| Cross-`Application` ordering evidenced by breaking `crds` and `kueue`, not asserted from documentation | `1.e2e.sh` step 3c stages A-C (this cell's own first-ever bootstrap, pristinely proving capacity fails to create NEW objects while either chart is broken) and step 12 (breaking each chart on an already-converged cell, reverted and recovery confirmed) |
| `karpenter-crd`/`karpenter` report no shared CRD | `1.e2e.sh` step 9 (`status.resources` kind=CustomResourceDefinition lists compared) |
| `kueue`/`karpenter` Healthy before any `NodePool`-launched node exists; smoke canary admitted and a node launches | `1.e2e.sh` steps 9 and 11 |
| Removing one `addon.yaml` orphans nothing; deleting the three bootstrap objects orphans `NodePool`/`EC2NodeClass`/the instance; re-running bootstrap.sh re-adopts without duplicating; destroy still terminates the instance | `1.e2e.sh` steps 13, 14 and 16 (creationTimestamp/instance-state comparisons) |
| Upgrade e2e's version-pair check catches a mismatch; a matched bump passes no-replacement and canary-stays-Running | `2.upgrade.sh` experiments A and B |
| Issue #41: every `gitops/addons/` entry is `tier: core`, every catalog entry `platform-optional` or `workload`, directory name equals `addon`, no name in both directories | `0.static.sh` (`check_addon_tiers.py`) |
| Issue #41: markers match their catalog entry (stem/`addon`/`fromCatalog`, cell-wide uniqueness, `dir`/`namespace`/`skipCrds`, tier, wave, `dependsOn`, `overridableKeys`) | `0.static.sh` (`check_addon_catalog_sync.py`) |
| Issue #41: `optional-pool` delivered to every cell as an untainted, on-demand pool | `1.e2e.sh` step 10 |
| Issue #41 Decision 4: add-then-remove cycle of a catalog entry on a real cell -- no `Application` without the marker, `Healthy`/`Synced` with it, removal orphans the resources; the component's pods land only where its own `nodeSelector` says | `1.e2e.sh` step 15 (`dcgm-exporter`, a disposable GPU `NodePool` test fixture, DaemonSet/Namespace UID comparisons) |
| CRD-schema-diff check not claimed met | `2.upgrade.sh`'s final `INFO` line states this explicitly; no assertion claims it |
| Every claim about upstream versions/capability behavior backed by a primary source or an "unconfirmed" marker | Enforced by this README and the scripts' own comments pointing at the issue's facts comment, not re-derived here |

## Assumptions behind these checks (flagged for the implementer and reviewer to reconcile)

Issue #25 leaves several names and a few mechanisms open; where it does,
this test suite picked one and is explicit about it rather than guessing
silently:

- **Discovery, not naming, for cell-specific resources.** The capacity
  pool's own name (`cells/<cluster>/capacity-pool/<pool>.yaml`'s `<pool>`),
  the resulting `Application` name, the `NodePool`/`EC2NodeClass`/
  `ResourceFlavor` names, and the smoke `LocalQueue`'s namespace and name
  are all discovered from the live cluster (expecting exactly one of
  each), never hardcoded, since decision 9 only requires "one pair" and
  names them nowhere.
- **The `platform` `AppProject`'s manifest is not a static file.** Decision
  7 says its `sourceRepos` is "computed by `bootstrap.sh` from the listing
  at its own checkout's HEAD each run", so this suite treats it as
  synthesized by the script, not a tracked YAML file -- `0.static.sh` does
  not `kubeconform` it (there is nothing to read); `1.e2e.sh` checks it
  only by `kubectl get appproject platform` existing after bootstrap.
- **The capability role has no output.** Decision 1 says so explicitly
  ("no output exposes...; never read by the script or any Application").
  Both `infra/foundation/tests/1.e2e.sh` (this PR's own addition there) and
  `gitops/tests/1.e2e.sh` find it the same way: `aws eks describe-capability`'s
  own `capability.roleArn` field. An elimination approach over
  `list-access-entries` (the one `STANDARD` entry that is neither
  `ADMIN_PRINCIPAL_ARN` nor an ARN containing `NAME`) was tried first and
  is wrong -- `argocd.tf` names the role `${var.name}-argocd-capability`,
  which embeds `NAME` too, so elimination always skips the entry this
  check needs (confirmed on a real cluster: both checks matched the same
  unrelated entry instead).
- **`cluster_arn`'s partition is not pinned to `aws`.** The regex accepts
  any partition, since the issue only specifies "an ARN, never an API
  server URL."
- **The ordering experiment (acceptance criterion 4) confirms, rather than
  assumes, which branch of decision 4 is live, and proves both the
  pristine and the already-converged form of the claim, on the same
  cell.** `1.e2e.sh` reads `platform.ApplicationSet`'s own
  `status.applicationStatus` directly: on a real cluster this is empty,
  confirming `RollingSync` is **not** active on the managed capability as
  of this PR, and that every `Application` syncs independently with
  `automated.selfHeal` instead (`check_gitops_contract.py` accepts either
  `RollingSync` steps or no `strategy.type` for this reason, in case a
  future capability version changes the answer).
  Decision 4's stronger claim ("capacity fails to create NEW objects
  depending on a broken crds step") cannot be observed once a chart's
  CRDs have ever synced successfully, since a Kubernetes CRD, once
  installed, persists regardless of whether the `Application` that
  installed it later goes unsynced. The only moment a cell is ever in a
  state where `karpenter-crd`'s and `kueue`'s own CRDs have never existed
  is its own first-ever bootstrap, so `1.e2e.sh` stages that first
  bootstrap itself in three steps (A/B/C), right after the "after"
  foundation apply and before any `capacity`/`smoke` object has ever been
  created: (A) both `karpenter-crd` and `kueue` broken -- nothing new can
  be created; (B) `kueue` still broken, `karpenter-crd` fixed; (C) fully
  restored. Stage B's result, confirmed on a real cluster and not
  assumed: `karpenter-crd`'s own `Application` reaches `Synced` and its
  CRDs become `Established`, but `capacity-pool` as a whole still cannot
  create `NodePool`/`EC2NodeClass` either, despite neither depending on
  `kueue`, because Argo CD validates every resource kind in one
  `Application`'s manifest set before applying any of them in one sync
  operation, not per-resource; a mixed-dependency `Application` is only
  as available as its least-available dependency. `capacity-pool`'s own
  `status.operationState` is read as the evidence for *why*, not only
  inferred from the outcome -- with three caveats, all confirmed on real
  runs and all now (issue #45) handled by `app_operation_state()`'s own
  single atomic `kubectl get -o json` read plus the polling loop around
  it below, never a plain jsonpath read of `.status.operationState.message`
  alone. First: capacity-pool already tried and failed to sync once in
  stage A, while `karpenter-crd`'s own CRDs did not exist yet, and that
  failure's message is a cached result Argo CD's own retry backoff can
  leave untouched for minutes; read right after `karpenter-crd` becomes
  `Established`, the message can still name `karpenter.k8s.aws`/
  `karpenter.sh` as undiscoverable too, left over from before this
  stage's own bootstrap -- stage B's `hard_refresh_app` calls (both
  `assert_stays_not_synced_refreshing`'s and the read loop's own) force a
  fresh *comparison* on every poll, which is necessary for "never reaches
  Synced" to mean anything current, but (see the third caveat) does not
  by itself make a stale operation message current. Second (issue #45,
  found running a PR stacked on this one): Argo CD's own controller
  (`controller/appcontroller.go`'s
  retry-preparation branch) overwrites `operationState.message` with a
  generic `"Retrying operation. Attempt #N"` string and sets
  `operationState.syncResult` to `nil`, in the same write, whenever a
  finished sync attempt's backoff has elapsed and the next retry is
  about to start -- a plain message-only read landing in that window
  sees neither the real cause nor any per-resource detail, by Argo CD's
  own design, not staleness or a bug on either side. Third, a distinct
  finding that came only from running the first version of this fix on a
  real cluster twice: a read that already satisfies "outside the nil
  window" (`phase` `Running`, `syncResult` non-nil) can still be stale in
  a different way, naming `karpenter.k8s.aws`/`karpenter.sh` as
  undiscoverable alongside `kueue.x-k8s.io` well after this same check's
  own earlier `wait_until` already confirmed `karpenter-crd` `Synced` and
  its CRD `Established`, and after a full `STAGE_B_TIMEOUT` (180s) of
  continuous `hard_refresh_app` calls. `hard_refresh_app` forces a fresh
  *comparison* (desired manifests vs. live state); it does not force a
  new *sync attempt* -- the operation's own retry runs on a schedule
  driven solely by `retryCount` and the backoff
  (`gitops/appsets/cells.ApplicationSet.yaml`'s `retry.backoff`: 10s,
  doubling, capped at 300s), independent of how often anything refreshes
  the comparison. A sync attempt that ran before `karpenter-crd`'s CRDs
  existed keeps being the most recent one Argo CD reports until the next
  attempt's own backoff interval elapses, which real runs put at several
  minutes, not the single post-refresh sleep the pre-#45 version assumed.
  `app_operation_state()` reads `phase`, `message`, `retryCount`, whether
  `syncResult` is present, `syncResult.resources[]`'s own per-resource
  messages, and `status.conditions[]`, all from one `kubectl get -o json`
  call (so none of them can be read from two different instants) and
  joined on `\x1F` (ASCII Unit Separator), never on a tab: a tab is
  classified as "IFS whitespace" by POSIX shells and collapses runs of
  the delimiter, which would silently drop an empty field (`retryCount`
  omitted at 0 by Argo CD's own `omitempty`) and shift every later column
  left by one -- caught in review, before this fix ever shipped, by testing
  `IFS=$'\t' read` against a row with an empty field. The final check
  polls it -- hard-refreshing again before each retry, which cannot
  speed up the next sync attempt specifically but keeps this stage's
  "force a fresh look every poll" intent for the comparison side -- and
  on each read: a terminal phase (`Error`/`Failed`) that still names
  karpenter's own groups fails immediately (Argo CD will not retry
  again, so this is final, not a transient reject-and-poll-again case); a
  terminal phase that does not mention karpenter, or `Running` with a
  non-nil `syncResult` that does not mention karpenter, is accepted;
  anything else (the nil-`syncResult` window, or `Running`/non-nil
  `syncResult` that still mentions karpenter) keeps polling, bounded by
  `STAGE_B_READ_TIMEOUT` (600s, long enough to span several retry cycles
  even at the capped 300s interval). The karpenter check matches the bare
  API group (`karpenter.k8s.aws`, `karpenter.sh`), never a
  version-anchored `.../v1`: a real run's own `syncResult.resources[]`
  message named the group and Kind with no version at all
  (`"...could not find karpenter.sh/NodePool for requested
  resource..."`). The top-level `message` and `syncResult.resources[]`'s
  own summary are always searched together, never one in place of the
  other: a real run showed the same underlying cause worded differently
  in each ("...the server could not find the requested resource" vs.
  "...could not find kueue.x-k8s.io/ResourceFlavor for requested
  resource...", with the phrase order reversed between them), so an
  earlier version of this fix that preferred `resources[]` whenever
  present failed this exact check on that real run even though its own
  nil-window handling had already worked correctly. Every read, not only
  the one finally asserted on, is logged (`phase`, `message`,
  `retryCount`, whether `syncResult` was present, the resources and
  conditions summaries), so a future flake in this same check leaves
  evidence of all of them, not only the one field the pre-#45 version
  captured. `status.conditions[]` is logged for diagnosis only, deliberately
  excluded from the matched text: whether Argo CD's
  `ComparisonError`/`SyncError` conditions (`controller/state.go`'s
  `CompareAppState`) cover this specific GVK-discovery failure class was
  not confirmed against a real cluster (issue #45's own root-cause
  writeup says so explicitly) at the time of this fix. This is a
  stronger form of decision 4's own claim than "only the dependent
  resource fails to create," and the earlier design of this test
  (expecting `NodePool`/`EC2NodeClass` to converge in stage B while only
  `ResourceFlavor` stayed blocked; then reading a stale message with no
  fresh attempt forced; then reading a real-but-uninformative "Retrying
  operation" message with no settle-past-the-nil-window logic; then, on
  this fix's own first real run, failing a correct nil-window read
  because it preferred a differently-worded field; then, on this fix's
  second real run, failing a correct and correctly-worded read because
  it was still a stale pre-CRD-fix attempt) was wrong for the same
  underlying reason five times across two PRs, each caught only by
  running it against a real cluster -- never by reasoning about Argo CD's
  behavior from documentation alone.
  Separately, step 12's break/restore experiments run against this same
  cell once already converged, and evidence the narrower, already-
  converged-cell claim that stage A/B/C above cannot re-observe once
  `capacity-pool`'s objects already exist: the broken `Application`
  itself (`crds` or `kueue`) leaves `Synced` and recovers once restored,
  within the retry bound; a chain that does not depend on the broken one
  (the `NodePool` depending on `crds`, unaffected by breaking `kueue`)
  stays unaffected; and capacity-pool's own already-created objects are
  not retroactively un-synced merely because a step they once depended on
  is now broken (Argo CD does not prune on a blocked/invalid sync by
  default).
- **The idempotency check uses `resourceVersion` for the Secret and
  AppProject, but a `.spec`-only fingerprint for the root Application.**
  A `kubectl apply` of byte-identical content does not change
  `resourceVersion`, so an unchanged value across two runs of an object
  with no other writer is direct evidence of a true no-op -- true for the
  Secret and AppProject, neither actively reconciled by anything.
  Argo CD's own application-controller continuously rewrites the root
  Application's `.status` independently of what `bootstrap.sh` writes
  (confirmed on a real cluster: its `resourceVersion` moved between two
  runs of `bootstrap.sh` with identical `--revision`, while the Secret's
  and AppProject's did not), so a raw `resourceVersion` comparison on that
  one object would report every run as "not idempotent" regardless of
  what `bootstrap.sh` does; comparing only its `.spec` (the part
  `bootstrap.sh` itself writes) is what the acceptance criterion is
  actually about. The `--revision`-only re-run check instead compares the
  Secret's own revision annotation and the root Application's
  `targetRevision` field directly, which `bootstrap.sh` sets verbatim --
  no fingerprint needed there.
- **The wrong-cluster abort test exercises both of decision 1's
  conditions, neither needing a second real cluster.** 7a forges
  `cluster_arn` in a copy of `--tf-outputs`, leaving the live kubeconfig
  pointed at the real cluster, so only the registration Secret's own
  cross-check (decision 1's second condition) can catch it. 7b instead
  forges `cluster_endpoint`, leaving `cluster_arn` correct, so only the
  kubeconfig-vs-`cluster_endpoint` check (decision 1's first condition --
  the one active on a genuine first bootstrap too, since it runs before
  the Secret even exists) can catch it. A single run exercises both,
  independently, by forging a different field each time rather than by
  pointing at a second cluster.
- **Step 15 (issue #41) starts by removing the `dcgm-exporter` marker,
  not by adding it.** Step 0 copies `gitops/cells/example-cell/` verbatim,
  and `example-cell` ships `addons/dcgm-exporter.yaml`, so the cell has had
  a synced `dcgm-exporter` `Application` since its first bootstrap. Step
  15 pushes a disposable branch without the marker (`no-dcgm-exporter`),
  confirms the `Application` disappears and its DaemonSet stays
  (orphaned), deletes that namespace so the re-add proves creation rather
  than re-adoption, then restores the marker. If `GITOPS_REVISION`'s own
  `gitops/cells/${NAME}/` has no marker, it adds `example-cell`'s on a
  disposable branch (`add-dcgm-exporter`) instead.
- **Step 15's GPU `NodePool`/`EC2NodeClass` is a test fixture, not part of
  the platform.** It is applied with `kubectl`, named `e2e-gpu-<hash of the
  run id>`, limited to one small NVIDIA instance (`g5`/`g6`/`g6e`, spot or
  on-demand, `limits.cpu: "8"`), copies role/AMI/discovery from the live
  `capacity-pool` `EC2NodeClass`, and is deleted at the end of step 15 and
  by `cleanup()` on failure. A pause Pod pinned to it triggers the node
  launch, since Karpenter does not launch nodes for DaemonSet pods. The
  `dcgm-exporter` `Application` is expected `Healthy`, not only `Synced`,
  while no NVIDIA node exists: Argo CD's DaemonSet health check is
  `Healthy` at `desiredNumberScheduled: 0`.
- **No separate experiment for Karpenter's OCI chart `skipCrds` content.**
  Checked structurally by `check_gitops_contract.py` (acceptance-criterion-
  adjacent, not itself one of the nine criteria) and confirmed in
  `1.e2e.sh` by each `Application`'s own resource list (criterion 5).

## Known issues

- `1.e2e.sh` and `2.upgrade.sh` each push disposable branches to
  `GITOPS_TEST_REPO_URL`, every one under `refs/heads/e2e/<run-id>/*`, and
  delete them on exit; a run that is killed without reaching the `EXIT`
  trap (for example `kill -9`) can leave one behind -- the next run's own
  `report_stale_disposable_branches()` lists any `e2e/*` branch older than
  a day for visibility, but only deletes ones in its own run's namespace.
  List and remove any other stale `refs/heads/e2e/*` branch by hand.
- Both e2e scripts build one foundation cell each; running them
  concurrently against the same `NAME`/`STATE_KEY` is rejected by the
  "state has no resources before apply" check, not silently corrupted.
- The log contains instance IDs, node names, group IDs and branch names of
  the test account. Redact them before pasting the log into an issue or
  pull request.
