# Foundation layer

`infra/foundation` is the Terraform root that builds the shell of one cell: everything that lives as long as the cluster and must exist before anything can run on it. It has one Terraform state per cell. Node pools, queues, device plugins, DRA drivers and workloads are not here; Argo CD and in-cluster controllers own them, using the outputs of this layer.

| Creates | Does not create |
| --- | --- |
| VPC with a public and a private subnet in every regular Availability Zone of the Region, an internet gateway, NAT gateway(s), discovery tag `karpenter.sh/discovery = <name>` on the private subnets and on the cluster security group | Karpenter itself, NodePools, EC2NodeClasses |
| Amazon EKS cluster (default 1.37), `authentication_mode = "API"`, control plane logs (`api`, `audit`, `authenticator`) with 30 days retention, access entries for `admin_principal_arns` | Kueue, JobSet, Trainer, LeaderWorkerSet |
| System managed node group (default 2 x `m7i.large`, AL2023, taint `CriticalAddonsOnly=true:NoSchedule`) | Device plugins and DRA drivers |
| EKS managed add-ons `vpc-cni`, `kube-proxy`, `eks-pod-identity-agent`, `coredns` with pinned versions | Capacity reservations |
| Karpenter prerequisites: controller IAM role associated with `kube-system/karpenter` through EKS Pod Identity, node IAM role with an `EC2_LINUX` access entry, encrypted interruption SQS queue and five EventBridge rules | Observability stack |
| Optional managed Argo CD capability (hub cells) | Anything that needs a running Karpenter |
| Teardown guard that removes Karpenter-launched instances before the network is destroyed | |

## Prerequisites

- Terraform 1.14.0 or later. The AWS provider is constrained to `~> 6.73` and locked in `.terraform.lock.hcl`.
- AWS CLI v2 and `bash` on the machine that runs `terraform destroy` (the teardown guard calls the AWS CLI), and `kubectl` to use the cluster.
- AWS credentials allowed to create VPC, EC2, EKS, IAM, SQS, EventBridge and CloudWatch Logs resources in the target account and Region.
- An S3 bucket for Terraform state, in a Region of your choice. State locking uses the S3 lock file (`use_lockfile`), so no DynamoDB table is needed.
- For the Argo CD capability only: an IAM Identity Center instance and the IDs of the groups that become Argo CD admins.

## Usage

Set the values for your environment first. `API_CIDR` is the network allowed to reach the public Kubernetes API endpoint (here: the public address of this machine). `ADMIN_ROLE_ARN` is the IAM role you are signed in with, which gets cluster admin through an access entry; Terraform does not give its own identity access implicitly. If you use an IAM user, set `ADMIN_ROLE_ARN` to the user ARN instead.

```bash
export CELL_NAME=example-cell
export AWS_REGION=us-east-1
export TF_STATE_BUCKET=example-terraform-state-bucket
export TF_STATE_REGION=us-east-1
export API_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
export ADMIN_ROLE_NAME="$(aws sts get-caller-identity --query Arn --output text | cut -d/ -f2)"
export ADMIN_ROLE_ARN="$(aws iam get-role --role-name "$ADMIN_ROLE_NAME" --query Role.Arn --output text)"
```

From the repository root, pass the values to Terraform as variables and initialize the S3 backend. The state key is `distai-platform/<name>/foundation`.

```bash
export TF_VAR_name="$CELL_NAME"
export TF_VAR_region="$AWS_REGION"
export TF_VAR_endpoint_public_access_cidrs="[\"${API_CIDR}\"]"
export TF_VAR_admin_principal_arns="[\"${ADMIN_ROLE_ARN}\"]"
cd infra/foundation
terraform init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=distai-platform/${CELL_NAME}/foundation" \
  -backend-config="region=${TF_STATE_REGION}" \
  -backend-config="use_lockfile=true"
```

Create the cell.

```bash
terraform apply
```

Connect to the cluster and check that two system nodes are Ready and the four add-ons are `ACTIVE`.

```bash
aws eks update-kubeconfig --name "$CELL_NAME" --region "$AWS_REGION"
kubectl get nodes
for addon in vpc-cni kube-proxy eks-pod-identity-agent coredns; do
  aws eks describe-addon --cluster-name "$CELL_NAME" --region "$AWS_REGION" \
    --addon-name "$addon" --query 'addon.[addonName,status]' --output text
done
```

Instead of `TF_VAR_*` variables you can keep the values in a `terraform.tfvars` file; start from [`terraform.tfvars.example`](./terraform.tfvars.example). `terraform.tfvars` is ignored by Git.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | (required) | Cell and cluster name; 3 to 32 lowercase letters, digits and hyphens, starting with a letter |
| `region` | `string` | (required) | AWS Region |
| `kubernetes_version` | `string` | `"1.37"` | EKS version; must have an entry in `local.addon_versions` in `eks.tf` |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | VPC CIDR, prefix length /16 to /20 |
| `single_nat_gateway` | `bool` | `true` | One NAT gateway for the VPC (test cells) instead of one per Availability Zone |
| `endpoint_public_access_cidrs` | `list(string)` | (required) | IPv4 CIDRs allowed to reach the public API endpoint; must not be empty and must not contain `0.0.0.0/0` |
| `admin_principal_arns` | `list(string)` | `[]` | IAM role or user ARNs given `AmazonEKSClusterAdminPolicy` through access entries |
| `system_node_group` | `object({ instance_types = optional(list(string), ["m7i.large"]), size = optional(number, 2) })` | `{}` | System node group; `size` is the fixed node count (1 to 10) |
| `argocd` | `object({ idc_instance_arn = string, idc_region = string, admin_group_ids = list(string) })` | `null` | Create the managed Argo CD capability when set |
| `tags` | `map(string)` | `{}` | Tags for every resource, applied through the provider's `default_tags` |

## Outputs

| Name | Description | Typical consumer |
| --- | --- | --- |
| `cluster_name` | EKS cluster name | Karpenter Helm value `settings.clusterName` |
| `cluster_endpoint` | Kubernetes API endpoint | Kubernetes clients of later layers |
| `cluster_certificate_authority_data` | Base64 cluster CA (public) | Kubernetes clients of later layers |
| `region` | AWS Region | Later layers |
| `vpc_id` | VPC ID | Later layers |
| `private_subnet_ids` | Private subnet IDs, one per Availability Zone | Load balancers, storage |
| `node_security_group_id` | The EKS cluster security group, used by every node | Rules for storage and load balancers |
| `karpenter_controller_role_arn` | Karpenter controller role; the Pod Identity association already exists | Reference only, no Helm value needed |
| `karpenter_node_role_name` | Node role for Karpenter nodes | EC2NodeClass `spec.role` |
| `karpenter_interruption_queue_name` | Interruption queue | Karpenter Helm value `settings.interruptionQueue` |
| `argocd_capability_arn` | Argo CD capability ARN, `null` when not created | Hub configuration |

An EC2NodeClass selects the subnets and the security group of the cell with `subnetSelectorTerms` and `securityGroupSelectorTerms` set to `tags: { karpenter.sh/discovery: <cluster_name> }`. Karpenter must run in the namespace `kube-system` with the service account `karpenter` (the chart's defaults when installed into `kube-system`) to receive the controller role.

## Teardown

```bash
terraform destroy
```

Run it with the same variables as `apply`. Karpenter is installed outside Terraform, so the instances it launches are not in this state, and if they are still running when the network is destroyed, their network interfaces block the deletion of the subnets and of the cluster security group. The teardown guard (`teardown.tf`, `scripts/teardown-guard.sh`) handles this during `terraform destroy` in this order:

1. Terraform detaches the permission policies of the Karpenter controller role, so a running Karpenter can no longer launch instances.
2. The guard terminates every instance in the cell's VPC that has the tag `karpenter.sh/nodepool` and the tag `eks:eks-cluster-name = <name>`, waits until they are terminated (repeating up to five rounds), and then deletes detached VPC CNI network interfaces in the VPC (description `aws-K8S-*`), launch templates tagged `karpenter.k8s.aws/cluster = <name>`, and the instance profiles Karpenter created for the node role.
3. Terraform destroys the cluster, the node role and the network.

If the guard fails, `terraform destroy` stops before any network resource is removed; fix the cause and run `terraform destroy` again. The guard runs with the credentials of the caller, which need `ec2:DescribeInstances`, `ec2:TerminateInstances`, `ec2:DescribeNetworkInterfaces`, `ec2:DeleteNetworkInterface`, `ec2:DescribeLaunchTemplates`, `ec2:DeleteLaunchTemplate`, `iam:ListInstanceProfilesForRole`, `iam:RemoveRoleFromInstanceProfile` and `iam:DeleteInstanceProfile`.

The guard removes only what Karpenter leaves in AWS. Resources that in-cluster controllers create from Kubernetes objects (load balancers from `Service` or `Ingress` objects, EBS volumes from `PersistentVolumeClaim` objects) belong to the layers that create those objects and must be removed there before the foundation is destroyed.

## Design notes

- **Subnets.** The VPC CIDR is split into eight blocks: blocks 0 to 6 are the private subnets (a /19 each with the default /16), block 7 is split into the public subnets (a /24 each). Only NAT gateways and load balancers use the public subnets; no instance gets a public IP address.
- **Control plane placement.** The control plane and the system node group use the private subnets except those in Availability Zones that EKS does not support for the control plane (`use1-az3`, `usw1-az2`, `cac1-az3`, from the Amazon EKS User Guide). Karpenter can still use every private subnet.
- **Add-on order.** The cluster is created with `bootstrap_self_managed_addons = false`, so every add-on is an EKS managed add-on owned by this layer. `vpc-cni`, `kube-proxy` and `eks-pod-identity-agent` are installed before the system node group so that its nodes become Ready; `coredns` is installed after it because it needs nodes to schedule on.
- **Security group.** Nodes use the cluster security group that EKS creates; it allows all traffic between nodes and the control plane. Karpenter selects it through the discovery tag added by `aws_ec2_tag`.
- **IAM.** The controller policies are those of the Karpenter v1.15 reference CloudFormation template, split into six customer managed policies. The interruption queue accepts messages only from the five EventBridge rules of this cell (`aws:SourceArn`) and only over TLS. The system and Karpenter node roles have `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryPullOnly` and `AmazonSSMManagedInstanceCore` (access through Session Manager instead of SSH).
- **Instance metadata.** Nodes use AL2023 AMIs, which require IMDSv2.
- **Argo CD.** `aws_eks_capability` with type `ARGOCD`, signing in through IAM Identity Center; `admin_group_ids` map to the Argo CD `ADMIN` role. The capability role has no permission policies; EKS gives the capability access to its own cluster.

## Known limits

- Add-on versions are pinned for Kubernetes 1.37 only. Another `kubernetes_version` is rejected at plan time until an entry is added to `local.addon_versions` in `eks.tf` (`aws eks describe-addon-versions --kubernetes-version <version>` lists the versions).
- The guard is a destroy-time provisioner. It does not run if `teardown.tf` is removed from the configuration or the `terraform_data.teardown_guard` resource is removed from the state before `terraform destroy`.
- The control plane log group keeps logs for 30 days and is deleted with the cell.
- IPv4 only.
