# Tests for the foundation layer

Two scripts check `infra/foundation` against the acceptance criteria of
[issue #20](https://github.com/littlemex/distai-platform/issues/20). They use
only the variables and outputs that the issue defines.

| Script | What it checks | Needs AWS | Duration |
| --- | --- | --- | --- |
| `0.static.sh` | `terraform fmt -check -recursive`, `terraform init -backend=false`, `terraform validate`, `tflint` | No | About 1 minute |
| `1.e2e.sh` | Apply, cluster shape, Karpenter from the outputs, spot launch, interruption handling, destroy with Karpenter still running, nothing left behind | Yes | About 45 to 70 minutes |

## Prerequisites

- Terraform `>= 1.14.0` and [TFLint](https://github.com/terraform-linters/tflint) for `0.static.sh`.
- For `1.e2e.sh` also the AWS CLI v2, `kubectl`, and Helm `>= 3.8` (OCI charts).
- An S3 bucket for the Terraform state.
- An IAM principal that can create a VPC, an EKS cluster, IAM roles, an SQS queue and EventBridge rules, and send messages to SQS. The test passes this principal as the cluster admin, so `ADMIN_PRINCIPAL_ARN` must be the principal that runs the test (for an assumed role, the IAM role ARN).
- A Region where the account has no cell with the same `NAME`, and spot capacity for at least one of the instance types in `E2E_INSTANCE_TYPES`.

`1.e2e.sh` creates billable resources (EKS control plane, two `m7i.large` system nodes, one NAT gateway, one or two small spot instances) and removes them at the end, also when a step fails.

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

The state is stored under the key `distai-platform/${NAME}/foundation`.

Optional variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `TERRAFORM` | `terraform` | Terraform binary |
| `KARPENTER_VERSION` | `1.15.2` | Karpenter chart version, must be `1.15.x` |
| `E2E_INSTANCE_TYPES` | `m7i.large,m6i.large,m5.large` | Instance types the spot NodePool may use; several types let Karpenter find a replacement after the interruption |
| `E2E_AMI_ALIAS` | `al2023@latest` | EC2NodeClass AMI alias; set a version such as `al2023@v20261112` to pin it |
| `E2E_WORK_DIR` | a new `mktemp -d` directory | Generated tfvars, kubeconfig, manifests and the Terraform data directory |
| `E2E_KEEP_ON_FAILURE` | `0` | `1` leaves the cell in place after a failure, for debugging; the script prints the destroy command |
| `E2E_LEFTOVER_GRACE_SECONDS` | `600` | How long to wait for terminating instances and deleting volumes or NAT gateways to disappear after destroy |
| `ARGOCD_IDC_INSTANCE_ARN`, `ARGOCD_IDC_REGION`, `ARGOCD_ADMIN_GROUP_IDS` | unset | When all three are set (group IDs comma separated), the test sets `argocd` and waits for the capability to become `ACTIVE` |

### What the test does

1. Writes a tfvars file with `name`, `region`, `endpoint_public_access_cidrs = [MY_CIDR]`, `admin_principal_arns = [ADMIN_PRINCIPAL_ARN]`, `argocd` and a run tag in `tags`; runs `terraform init` with the S3 backend and `terraform apply`.
2. Checks that all eleven outputs exist, that `argocd_capability_arn` is null when `argocd` is unset, and that `cluster_name` and `region` match the inputs.
3. Checks the cluster: EKS 1.37, authentication mode `API`, public endpoint limited to `MY_CIDR`, `kubectl` access through the access entry, two Ready nodes of the managed node group with the taint `CriticalAddonsOnly=true:NoSchedule`, and the add-ons `vpc-cni`, `coredns`, `kube-proxy` and `eks-pod-identity-agent` `ACTIVE`.
4. Installs Karpenter by Helm from `oci://public.ecr.aws/karpenter/karpenter` into `kube-system` with service account `karpenter`, `settings.clusterName` from `cluster_name` and `settings.interruptionQueue` from `karpenter_interruption_queue_name`. No IAM is created by the test: the controller gets its permissions from the Pod Identity association that the foundation layer creates.
5. Applies an EC2NodeClass (AMI alias, subnets and security groups selected by `karpenter.sh/discovery = NAME`, role `karpenter_node_role_name`) and a spot-only NodePool, then a one-replica Deployment that only fits on that NodePool. It waits until the pod runs on a Karpenter node and checks that the instance is spot.
6. Sends an EventBridge-shaped `EC2 Spot Instance Interruption Warning` for that instance to the interruption queue and waits until Karpenter reacts: the NodeClaim is deleted or marked for deletion, a `SpotInterrupted` event is recorded, or the controller logs `initiating delete from interruption message`. The Deployment then brings the pod back on a replacement spot instance.
7. With the NodePool, the Karpenter release and the replacement instance still in place, runs `terraform destroy` and requires it to succeed.
8. Requires every Karpenter instance of the run to be terminated, and no instance, ENI, NAT gateway or EBS volume to remain that carries the run tag, `karpenter.sh/discovery`, `kubernetes.io/cluster/NAME`, `eks:cluster-name`, `eks:eks-cluster-name` or `cluster.k8s.amazonaws.com/name`, or that sits in the cell's VPC. Finally the VPC must be gone.

Expected output (abridged, IDs redacted):

```text
PASS preflight: tools present, credentials valid
PASS terraform init with the S3 backend, key distai-platform/dp-e2e/foundation
PASS terraform apply (1100s)
PASS all eleven outputs present
PASS EKS 1.37, authentication mode API, public endpoint limited to MY_CIDR
PASS kubectl get nodes: 2 Ready system nodes
PASS add-on vpc-cni ACTIVE (...)
PASS Karpenter 1.15.2 installed in kube-system with service account karpenter
PASS pending pod runs on Karpenter spot node ... (m7i.large)
PASS Karpenter received the interruption message: NodeClaim ... marked for deletion at ...
PASS replacement Karpenter spot node ... runs the pod
PASS terraform destroy completed without manual steps (900s)
PASS no instance tagged for the cluster remains
PASS no eni tagged for the cluster remains
PASS no nat tagged for the cluster remains
PASS no volume tagged for the cluster remains
PASS VPC removed

RESULT PASS: all checks passed (run e2e-..., work dir ...)
```

The script exits with status 0 only when every check passed. On the first failed check it prints `FAIL` with the reason, deletes the test Deployment and NodePool, runs `terraform destroy`, lists anything that is left, and exits non-zero.

## Known issues

- Spot capacity can be unavailable for all types in `E2E_INSTANCE_TYPES`; the launch step then times out. Add more types and run again.
- The log contains instance IDs, node names and the queue name of the test account. Redact them before pasting the log into an issue or pull request.
