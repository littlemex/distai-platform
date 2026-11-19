# Tests for the gitops/ delivery layer

Three scripts check `gitops/` against the acceptance criteria of
[issue #25](https://github.com/littlemex/distai-platform/issues/25) (the
delivery layer), scoped to its first PR (decision 9): bootstrap, the
`crds`/`controllers`/`capacity` steps, the CPU `capacity-pool` skeleton, the
admin smoke queue, and the upgrade e2e's version-pair check. No
accelerators (`#19`), no per-team objects (`#22`) and no `sharedfs`/
notifications (`#18`/`#23`) ship in this PR, so this layer's tests do not
check them either.

| Script | What it checks | Needs AWS | Duration |
| --- | --- | --- | --- |
| `0.static.sh` | Required files, `bash -n`/`shellcheck` on every `*.sh` under `gitops/` (including this suite's own three scripts, not only `bootstrap.sh`), `yamllint` on every literal (non-templated) tracked YAML file, the structural contract of every `addon.yaml`/cells parameter file and both ApplicationSets (`check_gitops_contract.py`), `helm lint`/`helm template` of `charts/capacity-pool` and `charts/smoke`, `kubeconform` of the rendered output plus both ApplicationSets and the root Application against pinned upstream + CRD-catalog schemas, and `check_pinned_crds.py` validating the rendered CRD-backed objects against each pinned chart's own exact CRD versions | No | About 2 to 3 minutes |
| `1.e2e.sh` | Builds one foundation cell (with a temporary Identity Center group), the before/after RBAC change on the capability's own access entry, bootstrap idempotency / `--revision`-only re-run / wrong-cluster abort, the `crds`→`controllers`→`capacity` ordering (including two deliberately broken steps), the OCI chart and Git-file-generator-revision checks, no shared CRD between `karpenter-crd` and `karpenter`, the admin smoke canary through Kueue and Karpenter, one accidental generator-entry loss, one full bootstrap-object teardown and re-adopt, then destroy and leftovers | Yes | About 45 to 60 minutes |
| `2.upgrade.sh` | The mechanical version-pair check (decision 6) on a mismatched `karpenter`/`karpenter-crd` bump, then a matched bump against a live cell: no `Application` goes `Degraded`, the `NodePool`-launched instance is not replaced, and the canary pod stays `Running` throughout | Yes | About 50 to 65 minutes |

## Prerequisites

Everything in `infra/foundation/tests/README.md`'s prerequisites, plus:

- Helm `>= 3.8` (OCI charts), for `0.static.sh` only (`1.e2e.sh`/`2.upgrade.sh`
  never call `helm` themselves -- Argo CD installs every chart in-cluster).
- `uv` (for `0.static.sh`'s pinned `yamllint`/`pyyaml`), `curl` and
  `sha256sum` (for pinning `kubeconform` by checksum if it is not already on
  `PATH`). All three, plus Terraform, `kubectl`, the AWS CLI v2, `git` and
  `python3`, are already on the distai-platform EC2 test runner (see the
  "Running on the EC2 test runner" section below).
- An IAM Identity Center instance in the test account/Region, and an IAM
  principal that can call `identitystore:CreateGroup`/`DeleteGroup`
  (`1.e2e.sh`/`2.upgrade.sh` create and delete their own temporary group;
  unlike `infra/foundation/tests/1.e2e.sh`, no pre-existing group ID is
  taken as input), `eks:ListAccessEntries`, `eks:DescribeAccessEntry`,
  `eks:ListAssociatedAccessPolicies`, `eks:DescribeCapability`,
  `eks:ListCapabilities`.
- A GitHub token with **Contents: write** on the repository named by
  `GITOPS_TEST_REPO_URL` (default `https://github.com/littlemex/distai-platform.git`
  -- override to run against a fork you have write access to), read
  fresh from AWS SSM Parameter Store (SecureString) at `GITOPS_TEST_TOKEN_SSM_PARAM`
  (default `/relay/github/distai-platform`) in `GITOPS_TEST_TOKEN_SSM_REGION`
  (default `us-east-1`) -- never passed as an env var, a command-line
  argument, or written to `.git/config`: both scripts read it through a
  one-shot `GIT_ASKPASS` helper, deleted immediately after the one `git`
  command that needs it. `1.e2e.sh` and `2.upgrade.sh` each push one to
  three small, disposable branches, every one of them under
  `refs/heads/e2e/<run-id>/*` (a guard function refuses pushing or
  deleting anything outside that namespace), to exercise the ordering,
  generator-loss and upgrade experiments on a real Argo CD sync; `main`
  and `stable` are never touched. Each run also lists every remote
  `e2e/*` branch older than a day at its own start (reported, for a human
  to clean up) and deletes the ones already in its own `e2e/<run-id>/*`
  namespace. Branches are deleted again when the run ends, on success and
  on failure alike. Set `GITOPS_SKIP_ORDERING_EXPERIMENT=1` on `1.e2e.sh`
  if this token is unavailable; `2.upgrade.sh`, and `1.e2e.sh`'s own step
  13 generator-entry-loss experiment, have no such flag, since the write
  is exactly what their own acceptance criteria need.
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
all. Two more cell directories ship as of #28, `dp-a19-gpu` and
`dp-a19-trn` (one NVIDIA GPU pool and one Trainium pool, issue #28's own
light-tier accelerator fixtures, each carrying a method label
`ensure_cell_fixture()`'s own plain copy of `example-cell` would not).
With `GITOPS_RUN_ACCEL_E2E=1` (below), **`NAME` must be `dp-a19-gpu`**:
that extension builds only one cell directly (the plain `1.e2e.sh` flow
already above), and treats it as the GPU accelerator cell; `dp-a19-trn`
is never a valid value for `NAME` itself, only for `ACCEL_TRN_CELL_NAME`
-- the Trainium cell is a second, separate foundation cell the extension
builds and destroys on its own, in `ACCEL_TRN_REGION`:

```bash
export AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_REGION=<region with an IAM Identity Center instance>
export NAME=<cell name unused by any other cell in this account, any region>
export STATE_BUCKET=<your Terraform state bucket>
export STATE_REGION=<region of that bucket>
export ADMIN_PRINCIPAL_ARN=<the principal running this test>
export MY_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
export GITOPS_REVISION=<this PR's branch, already pushed to GitHub>
export ARGOCD_IDC_INSTANCE_ARN=<arn:aws:sso:::instance/ssoins-...>
export ARGOCD_IDC_REGION=<region of the Identity Center instance>
export ARGOCD_IDC_IDENTITY_STORE_ID=$(aws sso-admin describe-instance \
  --instance-arn "${ARGOCD_IDC_INSTANCE_ARN}" --query IdentityStoreId --output text)
cd gitops/tests
./1.e2e.sh 2>&1 | tee "/tmp/gitops-e2e-$(date +%Y%m%d%H%M%S).log"
# ./2.upgrade.sh instead, plus export UPGRADE_TO_KARPENTER_VERSION=<x>
```

(swap the trailing command and add `--env UPGRADE_TO_KARPENTER_VERSION=<x>`
for `2.upgrade.sh`). As with `infra/foundation/tests/1.e2e.sh`,
`AWS_PROFILE=default` on the runner (it authenticates via its IAM role
through IMDS) and `MY_CIDR` is the runner's own public IP, not the Mac's.

### Accelerator extension (issue #28, opt-in: `GITOPS_RUN_ACCEL_E2E=1`)

Adds the `accelerators` step's own real-hardware check, light tier (#16):
a Layer 1 pod on the existing cell's NVIDIA GPU pool, and a second
foundation cell built in a Trainium-capable Region for a Layer 1 pod on a
Neuron pool. Off by default, so an ordinary `1.e2e.sh` run (any `NAME`) is
unaffected.

| Variable | Required | Meaning |
| --- | --- | --- |
| `GITOPS_RUN_ACCEL_E2E` | no (default `0`) | Set to `1` to run this extension |
| `NAME` | yes, when set to `1` | Must equal `ACCEL_GPU_CELL_NAME` (default `dp-a19-gpu`) -- the GPU accelerator check reuses this script's own existing cell, it does not build a third one |
| `ACCEL_GPU_CELL_NAME` | no (default `dp-a19-gpu`) | Must match `NAME` and the `gitops/cells/<name>/` fixture this cell's pool comes from |
| `ACCEL_TRN_CELL_NAME` | no (default `dp-a19-trn`) | Name of the second, Trainium-only foundation cell this extension builds and destroys itself |
| `ACCEL_TRN_REGION` | no (default `ap-southeast-4`) | Region offering `trn2.3xlarge` spot capacity; the Identity Center instance stays wherever `ARGOCD_IDC_REGION` already points (#28 section E) |
| `ACCEL_GPU_TEST_IMAGE` | yes, when set to `1` | Container image with `nvidia-smi` on `PATH` (for example a CUDA base image), no default pinned in this repository |
| `ACCEL_TRN_TEST_IMAGE` | yes, when set to `1` | Container image with `neuron-ls` on `PATH` (a Neuron SDK image), no default pinned in this repository |
| `ACCEL_POD_TIMEOUT_SECONDS` | no (default `1800`) | How long to wait for each accelerator pod's node to launch |

```bash
runner/run.sh --ref "${GITOPS_REVISION}" \
  --env NAME=dp-a19-gpu \
  --env AWS_REGION=<Region offering g7/g6e/g5 spot capacity> \
  ... (every variable the plain 1.e2e.sh invocation above already needs) \
  --env GITOPS_RUN_ACCEL_E2E=1 \
  --env ACCEL_GPU_TEST_IMAGE=<a CUDA image reference> \
  --env ACCEL_TRN_TEST_IMAGE=<a Neuron SDK image reference> \
  --detach \
  -- bash gitops/tests/1.e2e.sh
```

## Acceptance criteria -> checks

| Acceptance criterion (issue #25) | Checked by |
| --- | --- |
| OCI chart reference accepted; Git-file-generator `revision:` resolves from the same Matrix's Cluster generator | `1.e2e.sh` step 9 (`${APP_KARPENTER}` Healthy+Synced from an `oci://` source; `${APP_CAPACITY_POOL}`'s `targetRevision` -- the `cells` ApplicationSet's own Git-file-generator `revision:` field, resolved from the Cluster generator's annotation -- matches the Secret's annotation; `${APP_KARPENTER}`'s own `targetRevision` is its pinned chart version, never a git revision, so it cannot be the check for this criterion) |
| Before this PR's foundation change: no `AmazonEKSClusterAdminPolicy` association on the capability's access entry (it already carries the two built-in Argo-CD-capability-management policies); after: `AmazonEKSClusterAdminPolicy` added | `1.e2e.sh` steps 2-3 (same cell, `GITOPS_BASE_REF` then this checkout's `infra/foundation`) |
| bootstrap.sh idempotent; `--revision`-only re-run updates the Secret annotation and root `Application`'s `targetRevision` together; wrong-cluster attempt aborts before any write | `1.e2e.sh` steps 5-7 (a `.spec`/annotation write-fingerprint, not a raw `resourceVersion`, compared before/after each re-run; step 7's 7a and 7b each forge one of decision 1's two fields independently) |
| Cross-`Application` ordering evidenced by breaking `crds` and `kueue`, not asserted from documentation | `1.e2e.sh` step 12 (two disposable branches, each reverted and recovery confirmed) |
| `karpenter-crd`/`karpenter` report no shared CRD | `1.e2e.sh` step 9 (`status.resources` kind=CustomResourceDefinition lists compared) |
| `kueue`/`karpenter` Healthy before any `NodePool`-launched node exists; smoke canary admitted and a node launches | `1.e2e.sh` steps 9 and 11 |
| Removing one `addon.yaml` orphans nothing; deleting the three bootstrap objects orphans `NodePool`/`EC2NodeClass`/the instance; re-running bootstrap.sh re-adopts without duplicating; destroy still terminates the instance | `1.e2e.sh` steps 13-15 (creationTimestamp/instance-state comparisons) |
| Upgrade e2e's version-pair check catches a mismatch; a matched bump passes no-replacement and canary-stays-Running | `2.upgrade.sh` experiments A and B |
| CRD-schema-diff check not claimed met | `2.upgrade.sh`'s final `INFO` line states this explicitly; no assertion claims it |
| Every claim about upstream versions/capability behavior backed by a primary source or an "unconfirmed" marker | Enforced by this README and the scripts' own comments pointing at the issue's facts comment, not re-derived here |

| Acceptance criterion (issue #28) | Checked by |
| --- | --- |
| Every `addon.yaml`/chart file in the Interface table exists and matches the stated shape | `0.static.sh` (`check_gitops_contract.py`, helm lint/template, kubeconform, `check_pinned_crds.py`) |
| A real `g7`/`g6e`/`g5` spot node (device-plugin method) runs a Layer 1 `nvidia.com/gpu` pod; `nvidia-smi` reports one GPU | `1.e2e.sh` `check_accel_layer1` on the GPU cell (`GITOPS_RUN_ACCEL_E2E=1`) |
| A real `trn2.3xlarge` spot node in `ap-southeast-4` (device-plugin method) runs a Layer 1 `aws.amazon.com/neuron` pod; `neuron-ls` reports one device | `1.e2e.sh` `check_accel_layer1` on the Trainium cell |
| Each method-labeled `NodePool` carries only the one advertiser its label selects | `1.e2e.sh` `check_accel_layer1`'s own node-level DaemonSet/namespace check |
| The `accelerators` step reaches Healthy+Synced for the device-plugin releases before anything is asserted about them | `1.e2e.sh` `check_accel_layer1`'s own `app_healthy_synced` wait |
| Both light-tier cells torn down with no leftover instance/ENI/launch template/volume | `1.e2e.sh` steps 15 and 19 (`report_leftovers`, parameterized per cell) |
| DRA `addon.yaml` files pass static checks; not required to launch a real DRA node | `0.static.sh`; `1.e2e.sh` only asserts the DRA Application exists in a distinct namespace from its device-plugin sibling, never schedules a pod onto it |

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
- **The ordering experiment (acceptance criterion 4) does not assume which
  branch of decision 4 is live.** `RollingSync` availability on the
  managed capability is marked "not confirmed" in the issue's own facts;
  `check_gitops_contract.py` accepts either `RollingSync` steps or no
  `strategy.type` (an `INFO` line records which), and `1.e2e.sh`'s breakage
  checks assert only what decision 4 claims is true in both branches
  (dependents fail to create; an unrelated chain is unaffected), not a
  specific controller mechanism.
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
