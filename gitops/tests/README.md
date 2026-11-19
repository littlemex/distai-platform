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
| `0.static.sh` | Required files, `bash -n`/`shellcheck` on every script, `yamllint` on every literal (non-templated) tracked YAML file, the structural contract of every `addon.yaml`/cells parameter file and both ApplicationSets (`check_gitops_contract.py`), `helm lint`/`helm template` of `charts/capacity-pool` and `charts/smoke`, and `kubeconform` of the rendered output plus both ApplicationSets and the root Application against pinned upstream + CRD-catalog schemas | No | About 2 to 3 minutes |
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
- Push access to `GITOPS_TEST_REMOTE` (default `origin`): `1.e2e.sh` and
  `2.upgrade.sh` each push one to three small, disposable branches (never
  `main`, never `stable`) to exercise the ordering, generator-loss and
  upgrade experiments on a real Argo CD sync, and delete them again when
  the run ends. Set `GITOPS_SKIP_ORDERING_EXPERIMENT=1` on `1.e2e.sh` if
  the runner has no push access; `2.upgrade.sh` has no such flag, since
  its entire purpose is the upgrade experiment.
- For `2.upgrade.sh`: a real, currently published Karpenter version
  different from `addons/karpenter/addon.yaml`'s pinned one (confirm with
  `helm show chart oci://public.ecr.aws/karpenter/karpenter --version <x>`);
  this test does not guess a "next" version, since nothing here can assume
  upstream's release cadence.

## Running on the EC2 test runner

Per the maintainer rule (2026-11-19), these never run on a developer
machine. From the repository root, on the Mac:

```bash
cd /Users/akazawt/works/data-science/claudecode/.claude/skills/distai-platform
runner/run.sh --ref <this-PR's-branch> -- bash gitops/tests/0.static.sh
```

For `1.e2e.sh`/`2.upgrade.sh`, export the same variables
`infra/foundation/tests/README.md`'s "End-to-end test" section documents
(`AWS_REGION`, `NAME`, `STATE_BUCKET`, `STATE_REGION`,
`ADMIN_PRINCIPAL_ARN`, `MY_CIDR`), plus this layer's own. **`NAME` must be
`example-cell`** for this PR: `cells.ApplicationSet.yaml`'s Git file
generator reads `gitops/cells/{{ .name }}/capacity-pool/*.yaml` and
`.../smoke/*.yaml` from the checked-in repository itself (decision 9
ships exactly one such pair, under `gitops/cells/example-cell/`, matching
`infra/foundation/README.md`'s own `NAME=example-cell` convention); any
other `NAME` has no matching directory, so the `capacity`/smoke step
never generates an Application at all (confirmed on a real cluster: "no
Application named `<NAME>-capacity-pool-<pool>` appeared" with any other
`NAME`) -- the mechanism is otherwise fine, there is just nothing at that
path to generate from. Future PRs that make the `capacity-pool`/`smoke`
fixture discoverable by any cell name (not just this one checked-in
example) should relax this:

```bash
export GITOPS_REVISION=<this PR's branch, already pushed to GitHub>
export ARGOCD_IDC_INSTANCE_ARN=<arn:aws:sso:::instance/ssoins-...>
export ARGOCD_IDC_REGION=<region of the Identity Center instance>
export ARGOCD_IDC_IDENTITY_STORE_ID=$(aws sso-admin describe-instance \
  --instance-arn "${ARGOCD_IDC_INSTANCE_ARN}" --query IdentityStoreId --output text)
ARN=$(runner/run.sh info | sed -n 's/^instance_role_arn=//p')
IP=$(runner/run.sh info | sed -n 's/^public_ip=//p')
runner/run.sh --ref "${GITOPS_REVISION}" \
  --env AWS_REGION=<region with an IAM Identity Center instance> \
  --env NAME=<cell name unused by any other cell in this account, any region> \
  --env STATE_BUCKET=<your Terraform state bucket> \
  --env STATE_REGION=<region of that bucket> \
  --env ADMIN_PRINCIPAL_ARN="$ARN" \
  --env MY_CIDR="${IP}/32" \
  --env GITOPS_REVISION="${GITOPS_REVISION}" \
  --env ARGOCD_IDC_INSTANCE_ARN="${ARGOCD_IDC_INSTANCE_ARN}" \
  --env ARGOCD_IDC_REGION="${ARGOCD_IDC_REGION}" \
  --env ARGOCD_IDC_IDENTITY_STORE_ID="${ARGOCD_IDC_IDENTITY_STORE_ID}" \
  --env AWS_PROFILE=default \
  --detach \
  -- bash gitops/tests/1.e2e.sh
```

(swap the trailing command and add `--env UPGRADE_TO_KARPENTER_VERSION=<x>`
for `2.upgrade.sh`). As with `infra/foundation/tests/1.e2e.sh`,
`AWS_PROFILE=default` on the runner (it authenticates via its IAM role
through IMDS) and `MY_CIDR` is the runner's own public IP, not the Mac's.

## Acceptance criteria -> checks

| Acceptance criterion (issue #25) | Checked by |
| --- | --- |
| OCI chart reference accepted; Git-file-generator `revision:` resolves from the same Matrix's Cluster generator | `1.e2e.sh` step 9 (`${APP_KARPENTER}` Healthy+Synced from an `oci://` source; its `targetRevision` matches the Secret's annotation) |
| Before this PR's foundation change: no RBAC on the capability's access entry; after: `AmazonEKSClusterAdminPolicy` | `1.e2e.sh` steps 2-3 (same cell, `GITOPS_BASE_REF` then this checkout's `infra/foundation`) |
| bootstrap.sh idempotent; `--revision`-only re-run updates the Secret annotation and root `Application`'s `targetRevision` together; wrong-cluster attempt aborts before any write | `1.e2e.sh` steps 5-7 (resourceVersion comparisons before/after each re-run) |
| Cross-`Application` ordering evidenced by breaking `crds` and `kueue`, not asserted from documentation | `1.e2e.sh` step 12 (two disposable branches, each reverted and recovery confirmed) |
| `karpenter-crd`/`karpenter` report no shared CRD | `1.e2e.sh` step 9 (`status.resources` kind=CustomResourceDefinition lists compared) |
| `kueue`/`karpenter` Healthy before any `NodePool`-launched node exists; smoke canary admitted and a node launches | `1.e2e.sh` steps 9 and 11 |
| Removing one `addon.yaml` orphans nothing; deleting the three bootstrap objects orphans `NodePool`/`EC2NodeClass`/the instance; re-running bootstrap.sh re-adopts without duplicating; destroy still terminates the instance | `1.e2e.sh` steps 13-15 (creationTimestamp/instance-state comparisons) |
| Upgrade e2e's version-pair check catches a mismatch; a matched bump passes no-replacement and canary-stays-Running | `2.upgrade.sh` experiments A and B |
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
  `gitops/tests/1.e2e.sh` find it the same way: the one `STANDARD` access
  entry that is neither `ADMIN_PRINCIPAL_ARN` nor an ARN containing `NAME`.
  If a future change adds a second such entry, this check needs a less
  ambiguous signal.
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
- **The idempotency and revision-update checks use `resourceVersion`,
  not a content diff.** A `kubectl apply` of byte-identical content does
  not change `resourceVersion`, so an unchanged value across two runs is
  direct evidence of a true no-op; this is the same technique
  `infra/foundation/tests/1.e2e.sh` uses for its own leftover detection,
  applied here to Kubernetes objects instead of AWS resources.
- **The wrong-cluster abort test forges only `cluster_arn`.** The live
  kubeconfig still points at the real cluster, so the check exercises the
  registration Secret's own cross-check (decision 1's second condition),
  not the kubeconfig-endpoint one -- both conditions are real per the
  issue, but a single run cannot violate both independently without two
  separate kubeconfigs, which would need a second cluster.
- **No separate experiment for Karpenter's OCI chart `skipCrds` content.**
  Checked structurally by `check_gitops_contract.py` (acceptance-criterion-
  adjacent, not itself one of the nine criteria) and confirmed in
  `1.e2e.sh` by each `Application`'s own resource list (criterion 5).

## Known issues

- `1.e2e.sh` and `2.upgrade.sh` each push disposable branches to
  `GITOPS_TEST_REMOTE` and delete them on exit; a run that is killed
  without reaching the `EXIT` trap (for example `kill -9`) can leave one
  behind. List and remove any `e2e-*`/`gitops-e2e-*`/`gitops-upgrade-*`
  branch found after an interrupted run.
- Both e2e scripts build one foundation cell each; running them
  concurrently against the same `NAME`/`STATE_KEY` is rejected by the
  "state has no resources before apply" check, not silently corrupted.
- The log contains instance IDs, node names, group IDs and branch names of
  the test account. Redact them before pasting the log into an issue or
  pull request.
