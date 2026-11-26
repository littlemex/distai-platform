# Foundation layer

`infra/foundation` is the Terraform root that builds the shell of one cell: everything that lives as long as the cluster and must exist before anything can run on it. It has one Terraform state per cell. Node pools, queues, device plugins, DRA drivers and workloads are not here; Argo CD and in-cluster controllers own them, using the outputs of this layer.

| Creates | Does not create |
| --- | --- |
| VPC with a public and a private subnet in every regular Availability Zone of the Region, an internet gateway, NAT gateway(s), discovery tag `karpenter.sh/discovery = <name>` on the private subnets and on the cluster security group | Karpenter itself, NodePools, EC2NodeClasses |
| Amazon EKS cluster (default 1.37), `authentication_mode = "API"`, control plane logs (`api`, `audit`, `authenticator`) with 30 days retention, access entries for `admin_principal_arns` | Kueue, JobSet, Trainer, LeaderWorkerSet |
| System managed node group (default 2 x `m7i.large`, AL2023, taint `CriticalAddonsOnly=true:NoSchedule`) behind a launch template with IMDSv2 required and `http_put_response_hop_limit = 1` | Device plugins and DRA drivers |
| EKS managed add-ons `vpc-cni`, `kube-proxy`, `eks-pod-identity-agent`, `coredns` with pinned versions; `vpc-cni` gets its AWS credentials through a Pod Identity association bound to `kube-system/aws-node`, and has `enableNetworkPolicy = "true"` | Capacity reservations, NetworkPolicy objects |
| Karpenter prerequisites: controller IAM role associated with `kube-system/karpenter` through EKS Pod Identity, node IAM role with an `EC2_LINUX` access entry, encrypted interruption SQS queue and five EventBridge rules | Observability stack |
| Optional managed Argo CD capability (hub cells) with a `role_mappings` list, so IAM Identity Center groups can be given the Argo CD `ADMIN`, `EDITOR` or `VIEWER` role | Per-team AppProjects, anything that needs a running Karpenter |
| Optional per-cell cost guardrail (issue #95): an `aws_budgets_budget` (`COST`, `MONTHLY`) scoped to this cell's own tagged resources, an Amazon SNS topic and subscriptions for it, notified at 80% and 100% of `budget_limit_usd` | AWS Cost Anomaly Detection (account-wide, a separate RFC) |
| Two teardown guards: one removes Karpenter-launched instances before the cluster is destroyed, one removes what the VPC CNI and EKS leave in the VPC before the network is destroyed, also after a failed `apply` | |

## Prerequisites

- Terraform 1.14.0 or later. The AWS provider is constrained to `~> 6.73` and locked in `.terraform.lock.hcl`.
- AWS CLI v2 and `bash` on the machine that runs `terraform destroy` (the teardown guards call the AWS CLI), and `kubectl` to use the cluster.
- AWS credentials allowed to create VPC, EC2, EKS, IAM, SQS, EventBridge and CloudWatch Logs resources in the target account and Region. The optional cost guardrail (`budget_limit_usd`) also needs permission to create and read AWS Budgets and Amazon SNS resources.
- An S3 bucket for Terraform state, in a Region of your choice. State locking uses the S3 lock file (`use_lockfile`), so no DynamoDB table is needed.
- A cell name that no other cell in the account uses, in any Region. IAM role and policy names include it, and IAM names are global to the account.
- The EC2 Spot service-linked role, if Karpenter is to launch spot instances. It exists once spot has been used in the account; otherwise create it once with `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com`. The Karpenter controller role is not allowed to create it.
- For the Argo CD capability only: an IAM Identity Center instance and the IDs of the groups to map to the Argo CD `ADMIN`, `EDITOR` and `VIEWER` roles (`role_mappings`).

## Usage

Set the values for your environment first. `MY_CIDR` is the network allowed to reach the public Kubernetes API endpoint (here: the public address of this machine). `ADMIN_PRINCIPAL_ARN` is the IAM role you are signed in with, which gets cluster admin through an access entry; Terraform does not give its own identity access implicitly. If you use an IAM user, set `ADMIN_PRINCIPAL_ARN` to the user ARN instead.

```bash
export NAME=example-cell
export AWS_REGION=us-east-1
export STATE_BUCKET=example-terraform-state-bucket
export STATE_REGION=us-east-1
export MY_CIDR="$(curl -fsS https://checkip.amazonaws.com)/32"
export ADMIN_ROLE_NAME="$(aws sts get-caller-identity --query Arn --output text | cut -d/ -f2)"
export ADMIN_PRINCIPAL_ARN="$(aws iam get-role --role-name "$ADMIN_ROLE_NAME" --query Role.Arn --output text)"
```

From the repository root, pass the values to Terraform as variables and initialize the S3 backend. The state key is `distai-platform/<region>/<name>/foundation`.

```bash
export TF_VAR_name="$NAME"
export TF_VAR_region="$AWS_REGION"
export TF_VAR_endpoint_public_access_cidrs="[\"${MY_CIDR}\"]"
export TF_VAR_admin_principal_arns="[\"${ADMIN_PRINCIPAL_ARN}\"]"
cd infra/foundation
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=distai-platform/${AWS_REGION}/${NAME}/foundation" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"
```

Create the cell.

```bash
terraform apply
```

Connect to the cluster and check that two system nodes are Ready and the four add-ons are `ACTIVE`.

```bash
aws eks update-kubeconfig --name "$NAME" --region "$AWS_REGION"
kubectl get nodes
for addon in vpc-cni kube-proxy eks-pod-identity-agent coredns; do
  aws eks describe-addon --cluster-name "$NAME" --region "$AWS_REGION" \
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
| `endpoint_public_access_cidrs` | `list(string)` | (required) | IPv4 CIDRs allowed to reach the public API endpoint; must not be empty, and each entry must be a network address with prefix length `/8` or longer |
| `admin_principal_arns` | `list(string)` | `[]` | IAM role or user ARNs given `AmazonEKSClusterAdminPolicy` through access entries |
| `system_node_group` | `object({ instance_types = optional(list(string), ["m7i.large"]), size = optional(number, 2) })` | `{}` | System node group; x86_64 instance types only (the AMI type is `AL2023_x86_64_STANDARD`); `size` is the fixed node count (1 or more) |
| `argocd` | `object({ idc_instance_arn = string, idc_region = string, role_mappings = list(object({ role = string, group_ids = list(string) })) })` | `null` | Create the managed Argo CD capability when set; `role` must be `ADMIN`, `EDITOR` or `VIEWER`, each used at most once, with a non-empty `group_ids` |
| `budget_limit_usd` | `number` | `null` | Monthly AWS Budgets limit in US dollars for this cell's own tagged resources; `null` creates no budget, Amazon SNS topic or subscription at all |
| `budget_notification_emails` | `list(string)` | `[]` | Email addresses subscribed to this cell's budget-alert topic; only used when `budget_limit_usd` is set, each needs its own AWS-sent confirmation click |
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
| `cluster_arn` | EKS cluster ARN | `gitops/bootstrap/bootstrap.sh`'s registration `Secret` (issue #25) |
| `argocd_namespace` | Namespace of the Argo CD capability's own objects, `null` when not created | `gitops/bootstrap/bootstrap.sh` (issue #25) |
| `budget_alert_topic_arn` | ARN of the cell's Amazon SNS budget-alert topic, `null` when `budget_limit_usd` is not set | An admin subscribing more destinations from the console |
| `budget_name` | Name of the cell's `aws_budgets_budget`, `null` when `budget_limit_usd` is not set | Reference only |

An EC2NodeClass selects the subnets and the security group of the cell with `subnetSelectorTerms` and `securityGroupSelectorTerms` set to `tags: { karpenter.sh/discovery: <cluster_name> }`. Karpenter must run in the namespace `kube-system` with the service account `karpenter` (the chart's defaults when installed into `kube-system`) to receive the controller role.

## Teardown

```bash
terraform destroy
```

Run it with the same variables as `apply`, also after an `apply` that failed part-way. Two kinds of resources in the cell's VPC are not in this state and block the deletion of the network if they are still there: the instances Karpenter launches (Karpenter is installed outside Terraform), and the network interfaces the VPC CNI creates (description `aws-K8S-*`) that stay behind detached when their node is terminated, together with the cluster security group that EKS creates and does not delete while such an interface still uses it. Two destroy-time guards (`teardown.tf`) handle them during `terraform destroy` in this order:

1. Terraform detaches the permission policies of the Karpenter controller role, so a running Karpenter can no longer launch instances.
2. The teardown guard (`scripts/teardown-guard.sh`) terminates every instance in the cell's VPC that has the tag `karpenter.sh/nodepool` and the tag `eks:eks-cluster-name = <name>`, waits until they are terminated (repeating up to five rounds), and then deletes detached VPC CNI network interfaces in the VPC, launch templates tagged `eks:eks-cluster-name = <name>` that also carry the tag key `karpenter.k8s.aws/ec2nodeclass` (how Karpenter v1 tags the templates it creates), and the instance profiles that hold the node role and carry Karpenter's tag `kubernetes.io/cluster/<name> = owned`.
3. Terraform destroys the cluster, the node groups and the node role.
4. The network guard (`scripts/network-guard.sh`) checks that no cluster named `<name>` exists any more, waits up to 10 minutes for the VPC CNI network interfaces left in the VPC to become detached and deletes them, and then deletes the security group in the VPC tagged `aws:eks:cluster-name = <name>`, retrying for up to 10 minutes while it is still in use. It terminates no instance.
5. Terraform destroys the network.

The teardown guard is created last, after the cluster and the system node group, so after a failed `apply` it may be missing. On the first `apply` of a cell this is harmless, since Karpenter (installed by Argo CD, a later layer) does not exist yet; a failed `apply` that re-applies this layer onto a cell where Karpenter is already running is outside what this guard alone can help with, and the cell's existing `terraform_data.teardown_guard` (already in the state from the earlier successful `apply`) is unaffected either way. The network guard is created right after the subnets, and the cluster depends on it, so it is in the state whenever the cluster is.

If a guard fails, `terraform destroy` stops before whatever it depends on: if `terraform_data.teardown_guard` fails, before the cluster, the node groups and every network resource, since it depends on all of them; if `terraform_data.network_guard` fails, before the subnets and the VPC specifically, since that is all it depends on - the NAT gateway, the route tables and the internet gateway have no dependency on it and can be destroyed on their own regardless. Fix the cause and run `terraform destroy` again. Each guard first checks that the AWS CLI acts on the same account as Terraform and stops otherwise. They run with the credentials of the caller, which need `sts:GetCallerIdentity`, `ec2:DescribeInstances`, `ec2:TerminateInstances`, `ec2:DescribeNetworkInterfaces`, `ec2:DeleteNetworkInterface`, `ec2:DescribeLaunchTemplates`, `ec2:DeleteLaunchTemplate`, `ec2:DescribeSecurityGroups`, `ec2:DeleteSecurityGroup`, `eks:DescribeCluster`, `iam:ListInstanceProfilesForRole`, `iam:ListInstanceProfileTags`, `iam:RemoveRoleFromInstanceProfile` and `iam:DeleteInstanceProfile`.

The guards remove only what Karpenter, the VPC CNI and EKS leave in AWS. Resources that in-cluster controllers create from Kubernetes objects (load balancers from `Service` or `Ingress` objects, EBS volumes from `PersistentVolumeClaim` objects) belong to the layers that create those objects and must be removed there before the foundation is destroyed.

## Design notes

- **Subnets.** The VPC CIDR is split into eight blocks: blocks 0 to 6 are the private subnets (a /19 each with the default /16), block 7 is split into the public subnets (a /24 each). Only NAT gateways and load balancers use the public subnets; no instance gets a public IP address.
- **Control plane placement.** The control plane and the system node group use the private subnets except those in Availability Zones that EKS does not support for the control plane (`use1-az3`, `usw1-az2`, `cac1-az3`, from the Amazon EKS User Guide). Karpenter can still use every private subnet.
- **Add-on order.** The cluster is created with `bootstrap_self_managed_addons = false`, so every add-on is an EKS managed add-on owned by this layer. `kube-proxy` and `eks-pod-identity-agent` are installed first, so that `eks-pod-identity-agent`'s DaemonSet exists in the cluster before `vpc-cni`'s does. `aws-node` (the `vpc-cni` DaemonSet) and the Pod Identity agent's DaemonSet both land on a node at essentially the same time when it joins, and `aws-node` needs the agent reachable to get its AWS credentials; `aws_eks_addon.vpc_cni` depends on `eks-pod-identity-agent` reaching `ACTIVE` so that every node that joins afterwards (the system node group, created later still, and any Karpenter node) always sees the agent's DaemonSet object already there. `vpc-cni` is in turn before the system node group so that its nodes become Ready; `coredns` is installed after it because it needs nodes to schedule on.
- **Security group.** Nodes use the cluster security group that EKS creates; it allows all traffic between nodes and the control plane. Karpenter selects it through the discovery tag added by `aws_ec2_tag`.
- **IAM.** The controller policies are those of the Karpenter v1.15 reference CloudFormation template, split into six customer managed policies. The interruption queue accepts messages from EventBridge only for the five rules of this cell (`aws:SourceArn`), and only over TLS; IAM principals of the account that have `sqs:SendMessage` in their own policies can still send to it (no test in this repository exercises this today -- the end-to-end test that used to send a synthetic interruption message was removed with the stand-in Karpenter install it belonged to, issue #25 decision 9). The system and Karpenter node roles have `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryPullOnly` and `AmazonSSMManagedInstanceCore` (access through Session Manager instead of SSH); they do not have `AmazonEKS_CNI_Policy`. That policy is instead on a dedicated role bound to `kube-system/aws-node` through an EKS Pod Identity association on the `vpc-cni` add-on, with a trust policy scoped the same way as the Karpenter controller role (`aws:SourceAccount` plus the `eks-cluster-arn`, `kubernetes-namespace` and `kubernetes-service-account` session tags that EKS Pod Identity sets).
- **Instance metadata.** Nodes use AL2023 AMIs, which require IMDSv2. The system node group also uses an explicit `aws_launch_template` with `http_put_response_hop_limit = 1`, so that a pod without host networking is at least two hops from the instance metadata service and cannot get a token at all; `aws-node` and the kubelet, one hop away, are unaffected. The launch template carries no `image_id` and no `instance_type`; `ami_type` and `instance_types` stay on the node group, and EKS still generates the AL2023 nodeadm bootstrap user data for that `ami_type` with no `user_data` in the template.
- **Argo CD.** `aws_eks_capability` with type `ARGOCD`, signing in through IAM Identity Center; each entry of `role_mappings` becomes one `rbac_role_mapping` block, mapping its `group_ids` to the Argo CD `ADMIN`, `EDITOR` or `VIEWER` role. The capability role has no permission policies of its own; EKS gives the capability's own access entry only the two built-in Argo-CD-capability-management policies by default (`AmazonEKSArgoCDClusterPolicy`, `AmazonEKSArgoCDPolicy`, confirmed on a real cluster -- these let the capability manage itself, never `AmazonEKSClusterAdminPolicy` or anything letting it create a `Namespace`/`ClusterRole`/`CustomResourceDefinition` for the charts and CRDs it is meant to deliver). An `aws_eks_access_policy_association` grants that access entry `AmazonEKSClusterAdminPolicy` at cluster scope too (issue #25): an AWS API call, so it stays in this layer rather than becoming a Kubernetes object delivered some other way. That association declares an explicit `depends_on` on `aws_eks_capability.argocd`, even though neither of its own arguments references it: the access entry it targets is a side effect of the capability, which exists only once the capability resource's own create has returned (the provider's waiter blocks until the capability reaches `ACTIVE`). On a single from-scratch `apply`, with no dependency edge the two resources have no attribute in common, so Terraform's graph schedules them concurrently and the association can call `AssociateAccessPolicy` before EKS has created the access entry at all, failing with `ResourceNotFoundException` (reproduced on the runner; a two-apply sequence never raced, since the capability was already long-`ACTIVE` by the second `apply`). `configuration.argo_cd.namespace` is set explicitly to `argocd` rather than left to the provider's default, so the `argocd_namespace` output never has to guess what EKS chose. Closing the remaining gap — a running capability still has zero registered clusters and nothing to deliver — is `gitops/bootstrap/bootstrap.sh`'s job, run once per cell after `terraform apply` (issue #25); it writes only Kubernetes objects, never AWS API calls, keeping this layer AWS-API-only and that script Kubernetes-API-only.
- **Multi-tenancy.** This layer gives the tenancy layer three guarantees to build on: a pod on a system node that does not use the host network cannot reach instance metadata (IMDSv2, hop limit 1) and so cannot obtain node-role credentials; the credentials of a node role (what instance metadata hands out) carry no CNI permissions (`vpc-cni` holds them alone, as a Pod Identity bound to `kube-system/aws-node`; someone with root on a node can still read that pod's service account token, as with any Pod Identity or IRSA role); and `NetworkPolicy` enforcement is already turned on, so adding a policy takes effect without any further add-on change. The `CriticalAddonsOnly` taint keeps ordinary workloads off system nodes only by convention (any pod can add a matching toleration); keeping tenant pods off is the tenancy layer's job, through an admission policy that rejects a toleration of `CriticalAddonsOnly` from anything but the controllers this layer and Karpenter install. Namespaces, per-team access entries, the `NetworkPolicy` objects themselves, Kueue queues and the shared filesystem are the tenancy layer's as well; this layer does not create any of them. The instance metadata settings above cover the system node group only: nodes that Karpenter launches take theirs from the EC2NodeClass, which the layer that delivers node pools owns. Karpenter's defaults are IMDSv2 required with a hop limit of 1, but each EC2NodeClass should set `metadataOptions` explicitly rather than rely on that default.

- **Cost guardrail.** `budget_limit_usd` and `budget_notification_emails` default to `null` and `[]`, the same declared-target, default-empty shape `var.argocd` already uses: nothing is created until a cell states its own limit. The `aws_budgets_budget`'s `cost_filter` only ever sees this one cell's own `distai-platform/cell`-tagged resources, never another cell's spend in the same account: the provider's own `default_tags` for everything this layer creates directly, plus an explicit `tag_specifications` block on the system node group's own launch template for its EC2 instances and EBS volumes (an Amazon EKS managed node group's own tags do not propagate to either on their own). A `lifecycle.precondition` on the budget fails `plan`, instead of silently creating a budget that tracks $0 forever, when `var.tags` does not actually carry that tag; it cannot, by itself, confirm every individual AWS-side resource received it. The Amazon SNS topic is this layer's own destination for both the 80% and the 100% `notification` block, kept separate from the budget resource's own `subscriber_email_addresses` argument so a subscriber can be added or removed later without another `apply` of this layer touching the budget itself; its own `aws_sns_topic_policy` grants `budgets.amazonaws.com` publish access, without which AWS Budgets creates and reaches `HEALTHY` but never actually delivers a notification. AWS Cost Anomaly Detection is out of scope for this layer; see issue #95 for why (account-wide, no per-cell `cost_filter` equivalent). This `cost_filter` also does not yet reach an EC2 instance Karpenter launches into a `capacity-pool` release (that chart's `EC2NodeClass` sets no `spec.tags`), the larger and more variable share of a cell's spend; tracked separately as issue #98.

## Known limits

- Add-on versions are pinned for Kubernetes 1.37 only. Another `kubernetes_version` is rejected at plan time until an entry is added to `local.addon_versions` in `eks.tf` (`aws eks describe-addon-versions --kubernetes-version <version>` lists the versions).
- The guards are destroy-time provisioners. A guard does not run if `teardown.tf` is removed from the configuration or its resource (`terraform_data.teardown_guard`, `terraform_data.network_guard`) is removed from the state before `terraform destroy`. A cell applied before `terraform_data.network_guard` existed gets it with the next `terraform apply` (one resource to add, no other change); run that before `terraform destroy`.
- The control plane log group keeps logs for 30 days and is deleted with the cell.
- `budget_limit_usd`'s `cost_filter` only reports spend under `distai-platform/cell` once that key is activated as a cost allocation tag in Billing, in two separate steps, both with their own delay: after the first `apply` that uses the tag, it can take up to 24 hours before the key even appears as activatable in Billing; activating it there can take up to another 24 hours before it starts affecting reported spend, and by default is not retroactive. Activation is account-wide and, in an AWS Organization, done once from the management (payer) account, not from whichever member account a cell lives in; this layer's own Terraform cannot do it on a per-cell basis (an `aws_ce_cost_allocation_tag` resource exists, but it is an account-wide setting, the same category as AWS Cost Anomaly Detection above -- out of scope for a per-cell layer). Until both steps are done, the budget still creates and still reaches `HEALTHY`, but tracks $0 regardless of real spend.
- IPv4 only.
