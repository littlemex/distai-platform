# Tests for the foundation layer

Two scripts check `infra/foundation` against the acceptance criteria of
[issue #20](https://github.com/littlemex/distai-platform/issues/20), including
the multi-tenancy acceptance criteria added to that issue (IMDS, CNI
permissions, NetworkPolicy, Argo CD role mappings) and the two additive
outputs and the access-policy association that
[issue #25](https://github.com/littlemex/distai-platform/issues/25)
(the delivery layer) decision 1 adds to this layer's `argocd.tf`. They use
only the variables and outputs that the two issues define. A third script
is the regression test for
[issue #26](https://github.com/littlemex/distai-platform/issues/26): destroy
after an apply that failed part-way.

Issue #25 decision 9 also removes this layer's own stand-in Karpenter
install from `1.e2e.sh`: Karpenter is now delivered by the managed Argo CD
capability, and that coverage (Karpenter healthy, a NodePool launches a
node, a canary admitted by Kueue) moved to `gitops/tests/1.e2e.sh`. This
script keeps only what belongs to the foundation layer itself: the outputs
Karpenter will need exist and are well-formed, and the node role carries no
CNI permissions, independent of anything that later runs on top of it.

| Script | What it checks | Needs AWS | Duration |
| --- | --- | --- | --- |
| `0.static.sh` | `terraform fmt -check -recursive`, `terraform init -backend=false`, `terraform validate`, `tflint`, `terraform test` with `variables.tftest.hcl` (input validation against a mocked AWS provider: accepted and rejected `argocd` role mappings and public endpoint CIDRs), and `guard-unit-tests.sh`/`network-guard-unit-tests.sh` (`scripts/teardown-guard.sh`/`scripts/network-guard.sh` against a scripted fake `aws` CLI) | No | About 1 minute |
| `1.e2e.sh` | State is empty before apply, cluster shape, outputs (including `cluster_arn`/`argocd_namespace`), the capability role's `AmazonEKSClusterAdminPolicy` access-policy association, IMDS hop limit, CNI permissions, NetworkPolicy enforcement, destroy, nothing left behind | Yes | About 20 to 25 minutes |
| `2.e2e-partial-apply.sh` | An apply forced to fail after the cluster and the system node group exist, then `terraform destroy` of that partial state with nothing left behind (issue #26) | Yes | About 20 to 30 minutes |

`e2e-lib.sh` is not run on its own: both end-to-end scripts source it. It
holds the shared helpers and is the one place that defines which AWS
resources count as "left behind" after a destroy.

## Prerequisites

- Terraform `>= 1.14.0` and [TFLint](https://github.com/terraform-linters/tflint) for `0.static.sh`.
- For `1.e2e.sh` also the AWS CLI v2 and `kubectl`. Helm is no longer needed by this script (issue #25 removed the stand-in Karpenter install); `gitops/tests/0.static.sh` needs it for `helm lint`/`helm template` (`gitops/tests/1.e2e.sh`/`2.upgrade.sh` never call Helm themselves -- Argo CD installs every chart in-cluster). `2.e2e-partial-apply.sh` needs only Terraform and the AWS CLI v2.
- An S3 bucket for the Terraform state.
- An IAM principal that can create a VPC, an EKS cluster, IAM roles, an SQS queue and EventBridge rules. The test passes this principal as the cluster admin, so `ADMIN_PRINCIPAL_ARN` must be the principal that runs the test (for an assumed role, the IAM role ARN).
- An IAM principal that can also call `iam:ListAttachedRolePolicies`, `eks:ListPodIdentityAssociations`, `eks:ListAccessEntries`, `eks:DescribeAccessEntry`, `eks:ListAssociatedAccessPolicies` and, with `argocd` set, `eks:DescribeCapability` (the test checks these in addition to what issue #20 already needed).
- A `NAME` that no other cell in the account uses, in any Region (IAM role and policy names include it and are global to the account).
- Outbound internet access from the private subnets (through the NAT gateway the layer creates) to `public.ecr.aws` and `docker.io`/`registry-1.docker.io`, to pull the pinned images below.

`1.e2e.sh` creates billable resources (EKS control plane, two `m7i.large` system nodes, one NAT gateway) and removes them at the end, also when a step fails.

## Pinned images

The IMDS and NetworkPolicy checks run short-lived pods from third-party
images, pinned by digest so that a tag being retagged upstream cannot change
what the test runs. Both digests were resolved from the registry's HTTP API
with `curl` plus an anonymous token (no `docker`, `crane` or `skopeo`
available in the environment that wrote this test) and cross-checked where
possible.

| Use | Image | Digest | How it was obtained |
| --- | --- | --- | --- |
| IMDS check (needs `curl`) | `docker.io/curlimages/curl:8.11.1` | `sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69` | Docker Hub token service (`auth.docker.io/token?service=registry.docker.io&scope=repository:curlimages/curl:pull`), then `GET /v2/curlimages/curl/manifests/8.11.1`; the digest is the `Docker-Content-Digest` response header (a multi-arch index covering `amd64`, `arm64`, `386`, `ppc64le`). |
| NetworkPolicy check (needs `nc`/`httpd` from BusyBox) | `public.ecr.aws/docker/library/busybox:1.37` | `sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec` | ECR Public's anonymous token service (`public.ecr.aws/token/?service=public.ecr.aws&scope=aws`), then `GET /v2/docker/library/busybox/manifests/1.37`. ECR Public does not return a `Docker-Content-Digest` header, so the digest is `sha256sum` of the exact response body; this was cross-checked by fetching the same tag from Docker Hub's registry API, which does return the header, and confirming the header and the two response bodies are identical. |

`curlimages/curl` was chosen over an `amazonlinux` or `alpine` base because it
is built specifically to contain `curl` and nothing else to verify without
running it; `busybox` was pulled through `public.ecr.aws`'s mirror of the
Docker Hub official image (same digest as the Docker Hub original, confirmed
above) so the NetworkPolicy check does not add a second registry dependency
beyond the ones `1.e2e.sh` already pulls from (`public.ecr.aws`).

Re-resolve and update both lines above (and the `IMDS_CURL_IMAGE` /
`NETPOL_BUSYBOX_IMAGE` variables near the top of `1.e2e.sh`) if either image
needs to move to a newer version.

## Static checks

```bash
cd infra/foundation/tests
./0.static.sh
```

Set `TERRAFORM` or `TFLINT` to use binaries that are not on the `PATH`:

```bash
export TERRAFORM=/opt/terraform/1.14.0/terraform
export TFLINT=/opt/tflint/tflint
./0.static.sh
```

Expected output ends with:

```text
PASS terraform fmt
PASS terraform init
PASS terraform validate
PASS tflint init
PASS tflint
PASS terraform test (input validation, mocked provider)
PASS node role already gone (issue #26): exit 0
PASS node role already gone (issue #26): logs it
PASS node role already gone (issue #26): deletes nothing
PASS instance profile already gone: exit 0
PASS instance profile already gone: logs it
PASS instance profile already gone: deletes nothing
PASS owned instance profile still deleted: exit 0
PASS owned instance profile still deleted: calls remove-role-from-instance-profile
PASS owned instance profile still deleted: calls delete-instance-profile
PASS other IAM error stays fatal (list-instance-profiles-for-role): exit non-zero
PASS other IAM error stays fatal (list-instance-profiles-for-role): does not claim already gone
PASS other IAM error stays fatal (list-instance-profiles-for-role): deletes nothing
PASS other IAM error stays fatal (list-instance-profile-tags): exit non-zero
PASS other IAM error stays fatal (list-instance-profile-tags): does not claim already gone
PASS other IAM error stays fatal (list-instance-profile-tags): deletes nothing
RESULT PASS: all guard unit tests passed
PASS guard unit tests (scripted fake AWS CLI)
PASS cluster still exists: exit 1
PASS cluster still exists: refuses
PASS cluster still exists: deletes nothing
PASS ordinary path: exit 0
PASS ordinary path: logs done
PASS ordinary path: calls delete-security-group once
PASS interfaces never settle: exit non-zero
PASS interfaces never settle: logs the IDs still present
PASS interfaces never settle: never reaches delete-security-group
PASS security group retried: exit 0
PASS security group retried: retries after DependencyViolation
PASS security group retried: calls delete-security-group twice
PASS security group already gone: exit 0
PASS security group already gone: logs already gone
PASS security group never released: exit non-zero
PASS security group never released: logs who still uses it
PASS security group never released: retried more than once
PASS describe-cluster itself fails: exit non-zero
PASS describe-cluster itself fails: does not claim refusing
PASS describe-cluster itself fails: deletes nothing
RESULT PASS: all network guard unit tests passed
PASS network guard unit tests (scripted fake AWS CLI)

RESULT PASS: all static checks passed
```

`guard-unit-tests.sh` and `network-guard-unit-tests.sh` (run as part of
`0.static.sh`, or on their own) run `scripts/teardown-guard.sh` and
`scripts/network-guard.sh` against a scripted fake `aws` on the `PATH`
instead of the real AWS CLI, plus a no-op `sleep` so the guards' own real
waits cost nothing here: no credentials or network calls, each case well
under a second. They share their assertion helper and the fake `sleep`
through `guard-unit-test-lib.sh`. They exist for error handling and
ordering the real end-to-end tests cannot reach on demand, because each
needs a specific AWS API response, or absence of one, at a specific moment.

`guard-unit-tests.sh`: the node role or one of its instance profiles being
deleted by something else (another destroy of the same cell racing this
one, an operator cleaning up by hand) between the guard listing it and
reading it again. Seen for real: `list-instance-profiles-for-role` returned
`NoSuchEntity` after the node role had already been deleted, right after
the guard had just finished terminating every instance (`us-east-1`,
2026-11-20), and `set -e` turned that into an aborted destroy (exit 254)
instead of "nothing to clean" (issue #26). Five cases, each checked against
both the guard's log output and, through a call log the fake `aws` writes,
whether it actually called `remove-role-from-instance-profile` /
`delete-instance-profile`: the node role already gone, an instance profile
already gone, the ordinary path (a profile Karpenter owns, both logged and
actually deleted), and a non-`NoSuchEntity` error (`AccessDenied`) at each
of the two list calls, confirming the guard still aborts and still deletes
nothing - the first three cases alone could not tell this fix from a
version that treats every IAM error, not only `NoSuchEntity`, as nothing to
clean.

`network-guard-unit-tests.sh`, seven cases: refusing while a cluster with
this name still exists (the safety property that keeps the guard from
touching a cluster it does not own the teardown of, checked with a real
interface and a real security group present, so "deletes nothing" is not
true only because there was nothing to delete), the ordinary path, waiting
out and timing out on interfaces that never become detached (likewise with
a real security group present), retrying the security group delete on
`DependencyViolation` and succeeding, treating `NotFound` on it as already
gone, timing out when it never stops being in use, and `describe-cluster`
itself failing with something other than `ResourceNotFoundException`
(plausible: `eks:DescribeCluster` is a permission this guard newly needs),
which must stay fatal and not be read as "the cluster is gone" - none of
which the real end-to-end tests can force on demand, since none of them
happens in a normal run.

## End-to-end test

```bash
export AWS_PROFILE=default
export AWS_REGION=us-east-2
export NAME=dp-e2e
export STATE_BUCKET=my-terraform-state-bucket
export STATE_REGION=us-east-1
export ADMIN_PRINCIPAL_ARN=arn:aws:iam::111122223333:role/Admin
export MY_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
cd infra/foundation/tests
./1.e2e.sh 2>&1 | tee "/tmp/foundation-e2e-$(date +%Y%m%d%H%M%S).log"
```

The state is stored under the key `distai-platform/${AWS_REGION}/${NAME}/foundation`.

Optional variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `TERRAFORM` | `terraform` | Terraform binary |
| `E2E_WORK_DIR` | a new `mktemp -d` directory | Generated tfvars, kubeconfig, manifests and the Terraform data directory |
| `E2E_KEEP_ON_FAILURE` | `0` | `1` leaves the cell in place after a failure, for debugging; the script prints the destroy command |
| `E2E_LEFTOVER_GRACE_SECONDS` | `600` | How long to wait for terminating instances and deleting volumes or NAT gateways to disappear after destroy |
| `ARGOCD_IDC_INSTANCE_ARN`, `ARGOCD_IDC_REGION`, `ARGOCD_ADMIN_GROUP_IDS` | unset | When all three are set (group IDs comma separated), the test sets `argocd` with one `role_mappings` entry (`role = "ADMIN"`, those group IDs) and waits for the capability to become `ACTIVE` |
| `ARGOCD_VIEWER_GROUP_IDS` | unset | With the three above also set, adds a `role_mappings` entry (`role = "VIEWER"`, these group IDs, comma separated), independently of `ARGOCD_EDITOR_GROUP_IDS` |
| `ARGOCD_EDITOR_GROUP_IDS` | unset | With the three above also set, adds a `role_mappings` entry (`role = "EDITOR"`, these group IDs, comma separated), independently of `ARGOCD_VIEWER_GROUP_IDS` |

### What the test does

1. Writes a tfvars file with `name`, `region`, `endpoint_public_access_cidrs = [MY_CIDR]`, `admin_principal_arns = [ADMIN_PRINCIPAL_ARN]`, `argocd` and a run tag in `tags`; runs `terraform init` with the S3 backend, checks that the state at that key has no resources yet (so the run cannot apply new code over an old cell), and runs `terraform apply`.
2. Checks that all thirteen outputs exist (including `cluster_arn` and `argocd_namespace`, issue #25 decision 1), that `argocd_capability_arn` is null when `argocd` is unset, that `cluster_arn` is a well-formed EKS cluster ARN for the input region and name, and that `cluster_name` and `region` match the inputs.
3. Checks the cluster: EKS 1.37, authentication mode `API`, public endpoint limited to `MY_CIDR`, `kubectl` access through the access entry, two Ready nodes of the managed node group with the taint `CriticalAddonsOnly=true:NoSchedule`, and the add-ons `vpc-cni`, `coredns`, `kube-proxy` and `eks-pod-identity-agent` `ACTIVE`. With `argocd` set, also waits for the capability to be `ACTIVE`, checks, through `aws eks describe-capability`, that its `rbacRoleMappings` list the ADMIN role mapping (and the VIEWER and/or EDITOR ones, for whichever of `ARGOCD_VIEWER_GROUP_IDS` and `ARGOCD_EDITOR_GROUP_IDS` were set) with the expected group IDs, and checks, through `aws eks list-access-entries`/`list-associated-access-policies`, that the capability's own IAM role (the one `STANDARD` access entry that is neither `ADMIN_PRINCIPAL_ARN` nor a node role) has an `AmazonEKSClusterAdminPolicy` association — issue #25 decision 1's `aws_eks_access_policy_association`, without which Argo CD cannot deliver anything to the cluster it runs on.
4. Runs a short-lived pod with no host networking on a system node (tolerating `CriticalAddonsOnly`) that tries to `PUT` an IMDSv2 token from `169.254.169.254`; the check passes when no token comes back. Also checks, with `aws ec2 describe-instances`, that every system node instance has `MetadataOptions.HttpTokens = required` and `MetadataOptions.HttpPutResponseHopLimit = 1`.
5. Checks, with `aws iam list-attached-role-policies`, that neither the Karpenter node role (`karpenter_node_role_name`) nor the system node group's node role (found with `aws eks describe-nodegroup`) has `AmazonEKS_CNI_Policy` attached; checks, with `aws eks list-pod-identity-associations`, that `kube-system`/`aws-node` has an association; and checks that the pod from the previous step, which has no host networking and no node role, still got a pod IP from the CNI.
6. Creates a namespace with a server pod (BusyBox `httpd`) and a client pod (BusyBox), and checks that the client reaches the server. Applies a deny-all ingress `NetworkPolicy` on the server and checks that the same request from the client now fails (retried for up to a minute, to allow time for the policy to take effect). Deletes the namespace.
7. Runs `terraform destroy` and requires it to succeed. No Karpenter-launched node exists in this test (that coverage is `gitops/tests/1.e2e.sh`'s), so destroy only removes the foundation's own resources.
8. Requires no instance, ENI, NAT gateway, EBS volume or launch template to remain that carries the run tag, `karpenter.sh/discovery`, `kubernetes.io/cluster/NAME`, `eks:cluster-name`, `eks:eks-cluster-name` or `cluster.k8s.amazonaws.com/name`, or (for instance, ENI and NAT gateway) that sits in the cell's VPC. Each of these checks fails loudly, with the AWS CLI's error text, if the underlying `aws ec2 describe-*` call itself fails for a reason other than the resource being gone (for example expired credentials or throttling); it never reports "nothing left" for a call that did not actually succeed. Finally the VPC must be gone (the same distinction applies to the `aws ec2 describe-vpcs` call).

Expected output (abridged, IDs redacted):

```text
PASS preflight: tools present, credentials valid
PASS terraform init with the S3 backend, key distai-platform/us-east-2/dp-e2e/foundation
PASS state at key distai-platform/us-east-2/dp-e2e/foundation has no resources before apply
PASS terraform apply (676s)
PASS all thirteen outputs present
PASS output cluster_arn is a well-formed EKS cluster ARN for us-east-2/dp-e2e
PASS cluster_name and region match the inputs
PASS EKS 1.37, authentication mode API, public endpoint limited to MY_CIDR
PASS kubectl reaches the cluster through the access entry
PASS kubectl get nodes: 2 Ready system nodes
PASS system nodes carry the CriticalAddonsOnly=true:NoSchedule taint
PASS add-on vpc-cni ACTIVE (...)
PASS add-on coredns ACTIVE (...)
PASS add-on kube-proxy ACTIVE (...)
PASS add-on eks-pod-identity-agent ACTIVE (...)
PASS a pod without host networking on a system node could not obtain an IMDSv2 token, while a host-network pod on the same node could
PASS system nodes require IMDSv2 (HttpTokens=required) with HttpPutResponseHopLimit=1
PASS neither the Karpenter node role nor the system node role (...) has AmazonEKS_CNI_Policy
PASS kube-system/aws-node has one EKS Pod Identity association, to its own role that carries exactly AmazonEKS_CNI_Policy
PASS a pod without host networking still got a pod IP (...) from the CNI
PASS client pod reaches the server pod before any NetworkPolicy is applied
PASS a deny-all ingress NetworkPolicy blocks traffic that worked before it was applied
PASS terraform destroy completed without manual steps (...)
PASS no instance tagged for the cluster remains
PASS no eni tagged for the cluster remains
PASS no nat tagged for the cluster remains
PASS no volume tagged for the cluster remains
PASS no launch-template tagged for the cluster remains
PASS VPC removed

RESULT PASS: all checks passed (run e2e-..., work dir ...)
```

(measured on a real run under the previous, Karpenter-installing version of this script: `terraform apply` 676s, `terraform destroy` 859s, about 32 minutes end to end; re-measure once this version runs, since removing the Karpenter install should shorten the apply and, with no Karpenter-launched instance, the destroy)

With `ARGOCD_IDC_INSTANCE_ARN`, `ARGOCD_IDC_REGION` and `ARGOCD_ADMIN_GROUP_IDS` set (`ARGOCD_VIEWER_GROUP_IDS` and `ARGOCD_EDITOR_GROUP_IDS` optional, independently of each other), the output also has, after `PASS Argo CD capability ACTIVE`:

```text
PASS Argo CD capability lists the ADMIN role mapping (...)
PASS Argo CD capability lists the VIEWER role mapping (...)
PASS Argo CD capability lists the EDITOR role mapping (...)
PASS Argo CD capability role has an AmazonEKSClusterAdminPolicy access-policy association
```

(the VIEWER line only when `ARGOCD_VIEWER_GROUP_IDS` was set, the EDITOR line only when `ARGOCD_EDITOR_GROUP_IDS` was set; each role-mapping check uses `aws eks describe-capability` to confirm that the capability's `rbacRoleMappings` lists that role with its group IDs; the access-policy line uses `aws eks list-access-entries`, `describe-access-entry` and `list-associated-access-policies` and runs regardless of which role mappings were set, since it checks the capability's own role, not a group).

The script exits with status 0 only when every check passed. On the first failed check it prints `FAIL` with the reason, deletes the IMDS check pod and the NetworkPolicy namespace, runs `terraform destroy`, lists anything that is left, and exits non-zero.

## Partial-apply test (issue #26)

`2.e2e-partial-apply.sh` checks that `terraform destroy` removes a cell
whose `terraform apply` failed part-way, without manual steps. It uses the
test-only variable `test_invalid_karpenter_node_principal_arn`: set to an
IAM role ARN that does not exist, it makes `aws_eks_access_entry.karpenter_node`
fail after the VPC, the EKS cluster and the system node group were created.
`terraform_data.teardown_guard` `depends_on` that access entry (`teardown.tf`),
so this is not only a late failure: it forces the exact state issue #26 is
about (the cluster and the node group exist, the guard does not) by
construction, because the access entry is the guard's own dependency and
not a sibling of it that merely happens to run around the same time.
Outside this test the variable stays `null`; `1.e2e.sh` never sets it, so
the normal run is not affected.

It takes the same environment as `1.e2e.sh` (Karpenter, Argo CD and
`kubectl` are not used). Run it after `1.e2e.sh` has finished, or with a
different `NAME`, since both use the state key
`distai-platform/${AWS_REGION}/${NAME}/foundation`:

```bash
export AWS_PROFILE=default
export AWS_REGION=us-east-2
export NAME=dp-e2e
export STATE_BUCKET=my-terraform-state-bucket
export STATE_REGION=us-east-1
export ADMIN_PRINCIPAL_ARN=arn:aws:iam::111122223333:role/Admin
export MY_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
cd infra/foundation/tests
./2.e2e-partial-apply.sh 2>&1 | tee "/tmp/foundation-e2e-partial-$(date +%Y%m%d%H%M%S).log"
```

Optional variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `TERRAFORM` | `terraform` | Terraform binary |
| `E2E_INVALID_KARPENTER_NODE_PRINCIPAL_ARN` | `arn:aws:iam::<account>:role/<NAME>-test-only-does-not-exist` | Value passed as `test_invalid_karpenter_node_principal_arn`; must be a well-formed IAM role ARN in the cell's own account that names a role that does not exist |
| `E2E_WORK_DIR` | a new `mktemp -d` directory | Generated tfvars, the apply log and the Terraform data directory |
| `E2E_KEEP_ON_FAILURE` | `0` | `1` leaves the cell in place after a failure, for debugging; the script prints the destroy command |
| `E2E_LEFTOVER_GRACE_SECONDS` | `600` | How long to wait for each kind of leftover to disappear after destroy |

### What the partial-apply test does

1. Writes a tfvars file like `1.e2e.sh` (with `argocd = null`) plus `test_invalid_karpenter_node_principal_arn`, runs `terraform init` with the S3 backend and checks that the state at that key has no resources yet.
2. Runs `terraform apply` and requires it to fail.
3. Requires that it failed where intended, not earlier: the apply output has an error diagnostic for `aws_eks_access_entry.karpenter_node` specifically (`with aws_eks_access_entry.karpenter_node,`, not merely the plan or a "Creating..." line mentioning that address), `aws eks describe-cluster` reports the cluster `ACTIVE`, `aws eks describe-nodegroup` reports the system node group `ACTIVE`, `aws eks describe-access-entry` for the real Karpenter node role ARN returns `ResourceNotFoundException`, and `terraform state list` does not contain `terraform_data.teardown_guard`. An apply that failed before the cluster and the node group existed fails the test, since it would not exercise issue #26. It also finds the VPC by the run tag, checks the cluster runs in it, and records the cluster security group that EKS created. For information only, it prints how many resources the partial state holds and which `terraform_data` resources are among them.
4. Plants a detached network interface (description `aws-K8S-i-issue26testonly`, carrying the recorded cluster security group) in one of the cell's private subnets, and confirms it carries that security group. Whether the system node group's own deletion leaves a real one behind, holding that group, is a race this test does not depend on (observed: in this minimal environment, with no pod load and no Karpenter running, it does not); planting one directly creates the exact artifact issue #26 describes, in the shape a Karpenter instance's own leftover interface takes once that instance is terminated outside the normal node group lifecycle - both halves of the symptom (the interface, and the security group it keeps in use), not only the interface.
5. Runs `terraform destroy` with the same tfvars file (so the same `test_invalid_karpenter_node_principal_arn`) and requires it to succeed.
6. Requires that nothing is left: the same kinds as `1.e2e.sh` (instance, ENI, NAT gateway, EBS volume, launch template), plus no detached VPC CNI interface in the VPC (`description` `aws-K8S-*`, `status` `available` — including the planted one) and no security group tagged `aws:eks:cluster-name = NAME`, tagged for the cell, or other than `default` in the VPC. Then the recorded cluster security group, the cluster and the VPC must be gone. As in `1.e2e.sh`, a failed AWS call is never read as "nothing left".

Expected output (abridged, IDs redacted):

```text
PASS preflight: tools present, credentials valid
PASS terraform init with the S3 backend, key distai-platform/us-east-2/dp-e2e/foundation
PASS state at key distai-platform/us-east-2/dp-e2e/foundation has no resources before apply
PASS terraform apply failed as intended (...s)
PASS after the failed apply the EKS cluster exists and is ACTIVE
PASS after the failed apply the system node group system exists and is ACTIVE
PASS no access entry for the real Karpenter node role exists
PASS terraform_data.teardown_guard is absent from the partial state, as issue #26 requires
PASS the cluster runs in this run's VPC, with the EKS-created cluster security group
INFO partial state holds ... resources; terraform_data in it: ...
INFO VPC CNI (aws-K8S-*) network interfaces in the VPC before destroy: ...
PASS planted a detached network interface (..., aws-K8S-* description) in subnet-..., carrying the cluster security group sg-...
PASS terraform destroy after a partial apply completed without manual steps (...s)
PASS no instance tagged for the cluster remains
PASS no eni tagged for the cluster remains
PASS no nat tagged for the cluster remains
PASS no volume tagged for the cluster remains
PASS no launch-template tagged for the cluster remains
PASS no cni-eni remains in the cell's VPC
PASS no security-group remains in the cell's VPC
PASS EKS cluster security group removed
PASS EKS cluster removed
PASS VPC removed

RESULT PASS: all checks passed (run e2e-partial-..., work dir ...)
```

It creates the same billable resources as the first half of `1.e2e.sh`
(EKS control plane, two `m7i.large` system nodes, one NAT gateway), for
about half an hour. On a failed check it runs `terraform destroy`; if that
destroy fails, it deletes the detached `aws-K8S-*` interfaces and the EKS
cluster security group in the cell's VPC (the leftovers of issue #26),
retries the destroy, lists anything that is left, and exits non-zero.

## Assumptions behind the multi-tenancy and delivery-layer checks

- The Argo CD role mapping check assumes that `var.argocd.role_mappings[].group_ids` becomes, in the real AWS API, a list of identities of type `SSO_GROUP` (one per group ID) under `rbacRoleMappings[].identities` — the only identity source the Terraform variable exposes. It checks the role name and the set of `SSO_GROUP` identity IDs under it; it does not separately assert the `type` field of each identity, since the test's inputs cannot distinguish an `SSO_GROUP` from an `SSO_USER` with the same ID.
- The CNI permission check assumes that the foundation layer continues to expose exactly one EKS managed node group (the system node group); it takes `nodegroups[0]` from `aws eks list-nodegroups`.
- The IMDS check assumes that a non-host-network pod cannot obtain a token when `HttpPutResponseHopLimit = 1` purely from the extra network hop into the pod's network namespace (the documented AWS behavior); it does not separately verify the mechanism, only the observable outcome (empty token).
- The NetworkPolicy check assumes the `vpc-cni` add-on has `enableNetworkPolicy` on cluster-wide (per issue #20 item 3); it does not read the add-on's `configurationValues` to confirm that flag directly, since the contract phrases the acceptance criterion as "a deny-all NetworkPolicy blocks traffic", not as a configuration check.
- Issue #25 decision 1 states that no Terraform output exposes the Argo CD capability role's own ARN ("the association is a direct Terraform resource reference, never read by the script or any Application"). An elimination approach over `aws eks list-access-entries` (the one `STANDARD`-type entry that is neither `ADMIN_PRINCIPAL_ARN` nor an ARN containing `NAME`) was tried first and is wrong: `argocd.tf` names the capability's own role `${var.name}-argocd-capability`, which embeds `NAME` too, so elimination always skips the very entry this check needs. This test instead reads the role directly from `aws eks describe-capability`'s own `capability.roleArn` field — no elimination, no ambiguity if a future change adds a second `STANDARD` access entry.
- `cluster_arn`'s format is asserted as `arn:<partition>:eks:<region>:<12-digit-account-id>:cluster/<name>`, matching the general AWS ARN shape and issue #25's own description of the field (the registration `Secret`'s `server` value, "an ARN, never an API server URL"); the exact partition is not pinned to `aws`, so the same check also passes in `aws-cn`/`aws-us-gov`.

## Known issues

- Spot capacity can be unavailable for all types in `E2E_INSTANCE_TYPES`; the launch step then times out. Add more types and run again.
- Terraform keeps creating resources that do not depend on the failed access entry, so which other resources the partial state holds (beyond the asserted absence of `terraform_data.teardown_guard`) depends on the configuration; the partial-apply test prints them but does not assert them.
- The log contains instance IDs, node names and the queue name of the test account. Redact them before pasting the log into an issue or pull request.
- The IMDS and NetworkPolicy checks pull third-party images (see "Pinned images" above) through the cell's NAT gateway; if the account or Region blocks that egress, both checks fail at the `kubectl apply` or pod-scheduling step rather than at the behavior they are meant to check.
