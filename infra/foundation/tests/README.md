# Tests for the foundation layer

Two scripts check `infra/foundation` against the acceptance criteria of
[issue #20](https://github.com/littlemex/distai-platform/issues/20), including
the multi-tenancy acceptance criteria added to that issue (IMDS, CNI
permissions, NetworkPolicy, Argo CD role mappings). They use only the
variables and outputs that the issue defines. A third script is the
regression test for
[issue #26](https://github.com/littlemex/distai-platform/issues/26): destroy
after an apply that failed part-way.

| Script | What it checks | Needs AWS | Duration |
| --- | --- | --- | --- |
| `0.static.sh` | `terraform fmt -check -recursive`, `terraform init -backend=false`, `terraform validate`, `tflint`, and `terraform test` with `variables.tftest.hcl` (input validation against a mocked AWS provider: accepted and rejected `argocd` role mappings and public endpoint CIDRs) | No | About 1 minute |
| `1.e2e.sh` | State is empty before apply, cluster shape, IMDS hop limit, CNI permissions, NetworkPolicy enforcement, Karpenter from the outputs, spot launch, interruption handling, destroy with Karpenter still running, nothing left behind | Yes | About 30 to 35 minutes |
| `2.e2e-partial-apply.sh` | An apply forced to fail after the cluster and the system node group exist, then `terraform destroy` of that partial state with nothing left behind (issue #26) | Yes | About 20 to 30 minutes |

`e2e-lib.sh` is not run on its own: both end-to-end scripts source it. It
holds the shared helpers and is the one place that defines which AWS
resources count as "left behind" after a destroy.

## Prerequisites

- Terraform `>= 1.14.0` and [TFLint](https://github.com/terraform-linters/tflint) for `0.static.sh`.
- For `1.e2e.sh` also the AWS CLI v2, `kubectl`, and Helm `>= 3.8` (OCI charts). `2.e2e-partial-apply.sh` needs only Terraform and the AWS CLI v2.
- An S3 bucket for the Terraform state.
- The EC2 Spot service-linked role in the account. It exists once spot has been used in the account; otherwise create it once with `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com`.
- An IAM principal that can create a VPC, an EKS cluster, IAM roles, an SQS queue and EventBridge rules, and send messages to SQS. The test passes this principal as the cluster admin, so `ADMIN_PRINCIPAL_ARN` must be the principal that runs the test (for an assumed role, the IAM role ARN).
- An IAM principal that can also call `iam:ListAttachedRolePolicies`, `eks:ListPodIdentityAssociations` and, with `argocd` set, `eks:DescribeCapability` (the test checks these in addition to what issue #20 already needed).
- A `NAME` that no other cell in the account uses, in any Region (IAM role and policy names include it and are global to the account), and spot capacity for at least one of the instance types in `E2E_INSTANCE_TYPES`.
- Outbound internet access from the private subnets (through the NAT gateway the layer creates) to `public.ecr.aws` and `docker.io`/`registry-1.docker.io`, to pull the pinned images below.

`1.e2e.sh` creates billable resources (EKS control plane, two `m7i.large` system nodes, one NAT gateway, one or two small spot instances) and removes them at the end, also when a step fails.

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

RESULT PASS: all static checks passed
```

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
| `KARPENTER_VERSION` | `1.15.2` | Karpenter chart version, must be `1.15.x` |
| `E2E_INSTANCE_TYPES` | `m7i.large,m6i.large,m5.large` | Instance types the spot NodePool may use; several types let Karpenter find a replacement after the interruption |
| `E2E_AMI_ALIAS` | `al2023@v20261112` | EC2NodeClass AMI alias, pinned to a released EKS-optimized AL2023 version for Kubernetes 1.37 |
| `E2E_WORK_DIR` | a new `mktemp -d` directory | Generated tfvars, kubeconfig, manifests and the Terraform data directory |
| `E2E_KEEP_ON_FAILURE` | `0` | `1` leaves the cell in place after a failure, for debugging; the script prints the destroy command |
| `E2E_LEFTOVER_GRACE_SECONDS` | `600` | How long to wait for terminating instances and deleting volumes or NAT gateways to disappear after destroy |
| `ARGOCD_IDC_INSTANCE_ARN`, `ARGOCD_IDC_REGION`, `ARGOCD_ADMIN_GROUP_IDS` | unset | When all three are set (group IDs comma separated), the test sets `argocd` with one `role_mappings` entry (`role = "ADMIN"`, those group IDs) and waits for the capability to become `ACTIVE` |
| `ARGOCD_VIEWER_GROUP_IDS` | unset | With the three above also set, adds a `role_mappings` entry (`role = "VIEWER"`, these group IDs, comma separated), independently of `ARGOCD_EDITOR_GROUP_IDS` |
| `ARGOCD_EDITOR_GROUP_IDS` | unset | With the three above also set, adds a `role_mappings` entry (`role = "EDITOR"`, these group IDs, comma separated), independently of `ARGOCD_VIEWER_GROUP_IDS` |

### What the test does

1. Writes a tfvars file with `name`, `region`, `endpoint_public_access_cidrs = [MY_CIDR]`, `admin_principal_arns = [ADMIN_PRINCIPAL_ARN]`, `argocd` and a run tag in `tags`; runs `terraform init` with the S3 backend, checks that the state at that key has no resources yet (so the run cannot apply new code over an old cell), and runs `terraform apply`.
2. Checks that all eleven outputs exist, that `argocd_capability_arn` is null when `argocd` is unset, and that `cluster_name` and `region` match the inputs.
3. Checks the cluster: EKS 1.37, authentication mode `API`, public endpoint limited to `MY_CIDR`, `kubectl` access through the access entry, two Ready nodes of the managed node group with the taint `CriticalAddonsOnly=true:NoSchedule`, and the add-ons `vpc-cni`, `coredns`, `kube-proxy` and `eks-pod-identity-agent` `ACTIVE`. With `argocd` set, also waits for the capability to be `ACTIVE` and checks, through `aws eks describe-capability`, that its `rbacRoleMappings` list the ADMIN role mapping (and the VIEWER and/or EDITOR ones, for whichever of `ARGOCD_VIEWER_GROUP_IDS` and `ARGOCD_EDITOR_GROUP_IDS` were set) with the expected group IDs.
4. Runs a short-lived pod with no host networking on a system node (tolerating `CriticalAddonsOnly`) that tries to `PUT` an IMDSv2 token from `169.254.169.254`; the check passes when no token comes back. Also checks, with `aws ec2 describe-instances`, that every system node instance has `MetadataOptions.HttpTokens = required` and `MetadataOptions.HttpPutResponseHopLimit = 1`.
5. Checks, with `aws iam list-attached-role-policies`, that neither the Karpenter node role (`karpenter_node_role_name`) nor the system node group's node role (found with `aws eks describe-nodegroup`) has `AmazonEKS_CNI_Policy` attached; checks, with `aws eks list-pod-identity-associations`, that `kube-system`/`aws-node` has an association; and checks that the pod from the previous step, which has no host networking and no node role, still got a pod IP from the CNI.
6. Creates a namespace with a server pod (BusyBox `httpd`) and a client pod (BusyBox), and checks that the client reaches the server. Applies a deny-all ingress `NetworkPolicy` on the server and checks that the same request from the client now fails (retried for up to a minute, to allow time for the policy to take effect). Deletes the namespace.
7. Installs Karpenter by Helm from `oci://public.ecr.aws/karpenter/karpenter` into `kube-system` with service account `karpenter`, `settings.clusterName` from `cluster_name`, `settings.interruptionQueue` from `karpenter_interruption_queue_name`, and `controller.env` set to `AWS_REGION` (the Karpenter pod tolerates `CriticalAddonsOnly` and runs on a system node, which after step 4 can no longer reach IMDS to discover its own Region, so it has to be told). No IAM is created by the test: the controller gets its permissions from the Pod Identity association that the foundation layer creates.
8. Applies an EC2NodeClass (AMI alias, subnets and security groups selected by `karpenter.sh/discovery = NAME`, role `karpenter_node_role_name`) and a spot-only NodePool, then a one-replica Deployment that only fits on that NodePool. It waits until the pod runs on a Karpenter node and checks that the instance is spot.
9. Sends an EventBridge-shaped `EC2 Spot Instance Interruption Warning` for that instance to the interruption queue and waits until Karpenter reacts: the NodeClaim is deleted or marked for deletion, a `SpotInterrupted` event is recorded, or the controller logs `initiating delete from interruption message`. The Deployment then brings the pod back on a replacement spot instance.
10. With the NodePool, the Karpenter release and the replacement instance still in place, runs `terraform destroy` and requires it to succeed.
11. Requires every Karpenter instance of the run to be terminated, and no instance, ENI, NAT gateway, EBS volume or launch template (Karpenter v1 tags the ones it creates with `eks:eks-cluster-name` and `karpenter.k8s.aws/ec2nodeclass`) to remain that carries the run tag, `karpenter.sh/discovery`, `kubernetes.io/cluster/NAME`, `eks:cluster-name`, `eks:eks-cluster-name` or `cluster.k8s.amazonaws.com/name`, or (for instance, ENI and NAT gateway) that sits in the cell's VPC. Each of these checks fails loudly, with the AWS CLI's error text, if the underlying `aws ec2 describe-*` call itself fails for a reason other than the resource being gone (for example expired credentials or throttling); it never reports "nothing left" for a call that did not actually succeed. Finally the VPC must be gone (the same distinction applies to the `aws ec2 describe-vpcs` call).

Expected output (abridged, IDs redacted):

```text
PASS preflight: tools present, credentials valid
PASS terraform init with the S3 backend, key distai-platform/us-east-2/dp-e2e/foundation
PASS state at key distai-platform/us-east-2/dp-e2e/foundation has no resources before apply
PASS terraform apply (676s)
PASS all eleven outputs present
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
PASS Karpenter 1.15.2 installed in kube-system with service account karpenter, controller.env AWS_REGION=us-east-2
PASS EC2NodeClass Ready: discovery tags select ... subnet(s), ... security group(s)
PASS pending pod runs on Karpenter spot node ... (m7i.large)
PASS Karpenter received the interruption message: NodeClaim ... marked for deletion at ...
PASS replacement Karpenter spot node ... runs the pod
PASS before destroy: NodePool, Karpenter release and instance(s) ... in place
PASS terraform destroy completed without manual steps (859s)
PASS Karpenter instance(s) ... terminated
PASS no instance tagged for the cluster remains
PASS no eni tagged for the cluster remains
PASS no nat tagged for the cluster remains
PASS no volume tagged for the cluster remains
PASS no launch-template tagged for the cluster remains
PASS VPC removed

RESULT PASS: all checks passed (run e2e-..., work dir ...)
```

(measured on a real run: `terraform apply` 676s, `terraform destroy` 859s, the whole script end to end about 32 minutes)

With `ARGOCD_IDC_INSTANCE_ARN`, `ARGOCD_IDC_REGION` and `ARGOCD_ADMIN_GROUP_IDS` set (`ARGOCD_VIEWER_GROUP_IDS` and `ARGOCD_EDITOR_GROUP_IDS` optional, independently of each other), the output also has, after `PASS Argo CD capability ACTIVE`:

```text
PASS Argo CD capability lists the ADMIN role mapping (...)
PASS Argo CD capability lists the VIEWER role mapping (...)
PASS Argo CD capability lists the EDITOR role mapping (...)
```

(the VIEWER line only when `ARGOCD_VIEWER_GROUP_IDS` was set, the EDITOR line only when `ARGOCD_EDITOR_GROUP_IDS` was set; each checks, through `aws eks describe-capability`, that the capability's `rbacRoleMappings` lists that role with its group IDs).

The script exits with status 0 only when every check passed. On the first failed check it prints `FAIL` with the reason, deletes the test Deployment, NodePool, the IMDS check pod and the NetworkPolicy namespace, runs `terraform destroy`, lists anything that is left, and exits non-zero.

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
export MY_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
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
3. Requires that it failed where intended, not earlier: the apply output mentions `aws_eks_access_entry.karpenter_node`, `aws eks describe-cluster` reports the cluster `ACTIVE`, `aws eks describe-nodegroup` reports the system node group `ACTIVE`, `aws eks describe-access-entry` for the real Karpenter node role ARN returns `ResourceNotFoundException`, and `terraform state list` does not contain `terraform_data.teardown_guard`. An apply that failed before the cluster and the node group existed fails the test, since it would not exercise issue #26. It also finds the VPC by the run tag, checks the cluster runs in it, and records the cluster security group that EKS created. For information only, it prints how many resources the partial state holds and which `terraform_data` resources are among them.
4. Plants a detached network interface (description `aws-K8S-i-issue26testonly`) in one of the cell's private subnets. Whether the system node group's own deletion leaves a real one behind is a race this test does not depend on (observed: in this minimal environment, with no pod load and no Karpenter running, it usually does not); planting one directly creates the exact artifact issue #26 describes, in the shape a Karpenter instance's own leftover interface takes once that instance is terminated outside the normal node group lifecycle.
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
PASS planted a detached network interface (..., aws-K8S-* description) in subnet-...
PASS terraform destroy after a partial apply completed without manual steps (...s)
PASS no instance tagged for the cluster remains
PASS no eni tagged for the cluster remains
PASS no nat tagged for the cluster remains
PASS no volume tagged for the cluster remains
PASS no launch-template tagged for the cluster remains
PASS no cni-eni tagged for the cluster remains
PASS no security-group tagged for the cluster remains
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

## Assumptions behind the multi-tenancy checks

- The Argo CD role mapping check assumes that `var.argocd.role_mappings[].group_ids` becomes, in the real AWS API, a list of identities of type `SSO_GROUP` (one per group ID) under `rbacRoleMappings[].identities` — the only identity source the Terraform variable exposes. It checks the role name and the set of `SSO_GROUP` identity IDs under it; it does not separately assert the `type` field of each identity, since the test's inputs cannot distinguish an `SSO_GROUP` from an `SSO_USER` with the same ID.
- The CNI permission check assumes that the foundation layer continues to expose exactly one EKS managed node group (the system node group); it takes `nodegroups[0]` from `aws eks list-nodegroups`.
- The IMDS check assumes that a non-host-network pod cannot obtain a token when `HttpPutResponseHopLimit = 1` purely from the extra network hop into the pod's network namespace (the documented AWS behavior); it does not separately verify the mechanism, only the observable outcome (empty token).
- The NetworkPolicy check assumes the `vpc-cni` add-on has `enableNetworkPolicy` on cluster-wide (per issue #20 item 3); it does not read the add-on's `configurationValues` to confirm that flag directly, since the contract phrases the acceptance criterion as "a deny-all NetworkPolicy blocks traffic", not as a configuration check.
- `AWS_REGION` is passed to Karpenter's `controller.env` unconditionally now, on the assumption that the chart does not break when IMDS happens to still be reachable (for example on a self-managed node without hop-limit 1); an explicit Region should never be wrong, since it's also what the test already requires as an input.

## Known issues

- Spot capacity can be unavailable for all types in `E2E_INSTANCE_TYPES`; the launch step then times out. Add more types and run again.
- Terraform keeps creating resources that do not depend on the failed access entry, so which other resources the partial state holds (beyond the asserted absence of `terraform_data.teardown_guard`) depends on the configuration; the partial-apply test prints them but does not assert them.
- The log contains instance IDs, node names and the queue name of the test account. Redact them before pasting the log into an issue or pull request.
- The IMDS and NetworkPolicy checks pull third-party images (see "Pinned images" above) through the cell's NAT gateway; if the account or Region blocks that egress, both checks fail at the `kubectl apply` or pod-scheduling step rather than at the behavior they are meant to check.
