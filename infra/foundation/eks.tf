locals {
  # Managed add-on versions, pinned per Kubernetes version. Refresh with:
  #   aws eks describe-addon-versions --kubernetes-version 1.37 --addon-name <name>
  addon_versions = {
    "1.37" = {
      "vpc-cni"                = "v1.23.3-eksbuild.1"
      "kube-proxy"             = "v1.37.0-eksbuild.39"
      "eks-pod-identity-agent" = "v1.4.1-eksbuild.3"
      "coredns"                = "v1.14.7-eksbuild.35"
    }
  }

  # DaemonSet add-ons are installed before the system node group so that its
  # nodes become Ready; CoreDNS (a Deployment) is installed after it. vpc-cni
  # is not in this set: it is created on its own, after eks-pod-identity-agent,
  # because aws-node now gets its AWS credentials through Pod Identity (see
  # aws_eks_addon.vpc_cni below).
  addons_before_nodes = ["kube-proxy", "eks-pod-identity-agent"]
  addons_after_nodes  = ["coredns"]

  # Control plane and system nodes use the private subnets in the Availability
  # Zones that EKS supports.
  cluster_subnet_ids = [
    for i, s in aws_subnet.private : s.id if !contains(local.eks_unsupported_zone_ids, local.zone_ids[i])
  ]

  cluster_log_types = ["api", "audit", "authenticator"]
}

# --- Cluster IAM role --------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Envelope encryption for Kubernetes Secrets (#63, filed as "SA3"): without
# this, aws_eks_cluster.this stores every Secret with only EKS's own
# platform-level encryption at rest, not the extra KMS layer the EKS best
# practices guide recommends and that this stack already has real Secrets
# needing (the cell-registration Secret, #51's own model-token Secret).
# EKS needs kms:DescribeKey/CreateGrant on the cluster's own IAM role - the
# key's default policy (full access to the account root) already lets that
# role's own account grant it, so no separate key policy statement is
# added here. enable_key_rotation is AWS's own recommended default for a
# key with no planned manual rotation process.
resource "aws_kms_key" "secrets" {
  description             = "${var.name} EKS Kubernetes Secrets envelope encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-eks-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

data "aws_iam_policy_document" "cluster_kms" {
  statement {
    actions   = ["kms:DescribeKey", "kms:CreateGrant"]
    resources = [aws_kms_key.secrets.arn]
  }
}

resource "aws_iam_role_policy" "cluster_kms" {
  name   = "eks-secrets-kms"
  role   = aws_iam_role.cluster.name
  policy = data.aws_iam_policy_document.cluster_kms.json
}

# --- Cluster -----------------------------------------------------------------

# Created by Terraform (not by EKS) so that the retention is bounded and the
# group is removed by terraform destroy.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = 30
}

resource "aws_eks_cluster" "this" {
  name                          = var.name
  version                       = var.kubernetes_version
  role_arn                      = aws_iam_role.cluster.arn
  bootstrap_self_managed_addons = false
  enabled_cluster_log_types     = local.cluster_log_types

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = local.cluster_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.endpoint_public_access_cidrs
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.secrets.arn
    }
    resources = ["secrets"]
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  lifecycle {
    precondition {
      condition     = contains(keys(local.addon_versions), var.kubernetes_version)
      error_message = "No pinned add-on versions for this kubernetes_version; add an entry to local.addon_versions in eks.tf."
    }
  }

  # The network guard must be in the state before the cluster exists, so that
  # terraform destroy after an apply that failed part-way still removes what
  # the cluster and its nodes leave in the VPC (see teardown.tf).
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_kms,
    aws_cloudwatch_log_group.cluster,
    terraform_data.network_guard,
  ]
}

# Karpenter selects the cluster security group (created by EKS, shared by the
# control plane and every node) through the discovery tag.
resource "aws_ec2_tag" "cluster_security_group_discovery" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.name
}

# --- Access entries ----------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# --- vpc-cni Pod Identity role -----------------------------------------------
#
# aws-node gets AWS credentials through EKS Pod Identity instead of through
# the node role, so AmazonEKS_CNI_Policy is on this role, scoped to
# kube-system/aws-node, and not on any node role (see local.node_managed_policies
# below). Trust conditions follow the same pattern as the Karpenter controller
# role in karpenter.tf: EKS Pod Identity sets these session tags, so only the
# aws-node service account of this cluster can assume the role.

locals {
  vpc_cni_namespace       = "kube-system"
  vpc_cni_service_account = "aws-node"
}

data "aws_iam_policy_document" "vpc_cni_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [local.cluster_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.vpc_cni_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.vpc_cni_service_account]
    }
  }
}

resource "aws_iam_role" "vpc_cni" {
  name               = "${var.name}-vpc-cni"
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_assume.json
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# --- System node group -------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.${local.dns_suffix}"]
    }
  }
}

locals {
  # AmazonEKS_CNI_Policy is not here: a pod on a node with this role cannot
  # attach or detach ENIs, because that permission now lives only on the
  # vpc-cni Pod Identity role above, bound to kube-system/aws-node.
  #
  # AmazonSSMManagedInstanceCore is not here either (#63, independent
  # security-axis review pass, filed as "SA3"): that managed policy's own
  # `ssm:GetParameter`/`ssm:GetParameters` are granted on Resource "*"
  # (confirmed against the live policy, version v2, 2026-11-23), letting
  # any process on a node (a hostNetwork Pod, a container escape) read
  # every plaintext SSM parameter in the account by name, region-wide -
  # broader than Session Manager connectivity, the only thing this
  # platform's own runbooks (SSM Session Manager, no SSH) actually need
  # from it. aws_iam_role_policy.node_ssm_session_only below grants
  # exactly the actions Session Manager's own documentation lists for
  # that (ssmmessages/ec2messages plus ssm:UpdateInstanceInformation so
  # the instance registers as a managed node at all), dropping
  # GetParameter/GetParameters, GetDocument, PutInventory and every
  # patch/association/compliance action the managed policy also grants
  # that this platform's nodes have no documented use for.
  node_managed_policies = [
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
  ]
}

resource "aws_iam_role" "system_node" {
  name               = "${var.name}-system-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "system_node" {
  for_each = toset(local.node_managed_policies)

  role       = aws_iam_role.system_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# Session Manager connectivity only, not AmazonSSMManagedInstanceCore's full
# grant (see the comment on local.node_managed_policies above). Actions and
# their Resource "*" scoping are copied verbatim from that managed policy's
# own two ssmmessages/ec2messages statements, confirmed against the live
# policy (v2, 2026-11-23): neither service supports a narrower resource
# scope (every real-world example and this account's own managed policy use
# "*" for both). ssm:UpdateInstanceInformation is the one ssm:* action kept,
# since without it the instance never registers as a managed node and
# Session Manager cannot find it at all.
data "aws_iam_policy_document" "node_ssm_session_only" {
  statement {
    sid       = "SessionManagerChannel"
    actions   = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
    resources = ["*"]
  }

  statement {
    sid       = "SessionManagerEc2Messages"
    actions   = ["ec2messages:AcknowledgeMessage", "ec2messages:DeleteMessage", "ec2messages:FailMessage", "ec2messages:GetEndpoint", "ec2messages:GetMessages", "ec2messages:SendReply"]
    resources = ["*"]
  }

  statement {
    sid       = "SessionManagerRegistration"
    actions   = ["ssm:UpdateInstanceInformation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "system_node_ssm_session_only" {
  name   = "ssm-session-only"
  role   = aws_iam_role.system_node.name
  policy = data.aws_iam_policy_document.node_ssm_session_only.json
}

# IMDSv2 only, one hop: a pod on a system node that does not use the host
# network is at least two hops from the instance metadata service (one hop
# out of the pod network namespace, one more into the instance), so it gets
# no token and cannot reach IMDS at all. aws-node (host network) and the
# kubelet are one hop away and are unaffected. No image_id or instance_type
# here: ami_type stays on the node group below, and with no user_data in the
# template either, EKS still generates the AL2023 nodeadm bootstrap config
# for that ami_type. update_default_version keeps this template's own
# "$Default" pointer current for anything that references it outside this
# node group.
resource "aws_launch_template" "system_node" {
  name        = "${var.name}-system-node"
  description = "IMDSv2 hardening for the system node group"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Every value below except "encrypted" matches this node group's own AMI
  # (ami_type AL2023_x86_64_STANDARD)'s own root block device exactly -
  # confirmed against a real `describe-images` of the SSM recommended-AMI
  # parameter this platform already pins to (#50/karpenter-crd's own
  # comment), 2026-11-23: device /dev/xvda, 20 GiB, gp3, 3000 IOPS, 125
  # MiB/s throughput, delete-on-termination true, encrypted FALSE at the
  # AMI's own snapshot. Account-level "EBS encryption by default" is one
  # way to fix that, but nothing in this layer enforces the account has it
  # on (#63, filed as "SA3") - without this block, a node's root volume is
  # only encrypted if someone else set that account-wide setting. This
  # block makes the guarantee explicit here instead, with every other
  # field pinned to the AMI's own current default so this change is
  # encryption only, not a capacity or performance change.
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
    }
  }

  # Amazon EKS managed node group tags do not propagate to the node group's
  # own Auto Scaling group or its EC2 instances (Amazon EKS User Guide,
  # "Create a managed node group" -- console Tags field help text: "These
  # tags don't propagate to other resources in the node group, such as
  # Auto Scaling groups or instances"). Separately, the provider's own
  # default_tags auto-merges only into a resource's own top-level tags/
  # tags_all, never into a nested repeated block like tag_specifications,
  # so writing var.tags here explicitly is required either way; it is not
  # covered by default_tags doing this everywhere else in this layer. The
  # Amazon EKS User Guide's own "Customize managed nodes with launch
  # templates" page, "Tagging Amazon EC2 instances" section, names
  # TagSpecification on the launch template as the supported way to tag a
  # managed node group's own instances and volumes directly. merge() adds
  # a Name tag unconditionally: a TagSpecification with zero tags (every
  # cell that leaves var.tags at its own default {}) is rejected by the
  # EC2 API, so this must never send var.tags alone.
  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-system-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name}-system-node" })
  }

  update_default_version = true
}

resource "aws_eks_addon" "before_nodes" {
  for_each = toset(local.addons_before_nodes)

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = local.addon_versions[var.kubernetes_version][each.value]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# vpc-cni, after eks-pod-identity-agent: aws-node and eks-pod-identity-agent
# are both DaemonSets, and a fresh node runs them at essentially the same
# time. aws-node needs the agent's local credential endpoint to be reachable
# to get its AWS credentials through Pod Identity. This dependency only
# orders the two aws_eks_addon objects, not the pods each DaemonSet puts on
# a given node: depending on eks-pod-identity-agent reaching ACTIVE makes
# sure its DaemonSet object exists in the cluster before vpc-cni's does, for
# every node that joins afterwards (the system node group, created later
# still, and any Karpenter node), so the agent's pod is always scheduled on
# a node no later than aws-node's. It does not guarantee the agent's pod is
# already Ready first; aws-node tolerates that by retrying until the local
# credential endpoint answers, so a node still comes up correctly even if
# its aws-node pod starts fetching credentials before the agent pod is up.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = local.addon_versions[var.kubernetes_version]["vpc-cni"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Turns on NetworkPolicy enforcement in the vpc-cni network policy agent.
  # The NetworkPolicy objects are the tenancy layer's; with none, traffic is
  # unchanged, and a policy takes effect as soon as it is added.
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  pod_identity_association {
    service_account = local.vpc_cni_service_account
    role_arn        = aws_iam_role.vpc_cni.arn
  }

  depends_on = [
    aws_eks_addon.before_nodes,
    aws_iam_role_policy_attachment.vpc_cni,
  ]
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.system_node.arn
  subnet_ids      = local.cluster_subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = var.system_node_group.instance_types

  launch_template {
    id      = aws_launch_template.system_node.id
    version = aws_launch_template.system_node.latest_version
  }

  scaling_config {
    desired_size = var.system_node_group.size
    min_size     = var.system_node_group.size
    max_size     = var.system_node_group.size
  }

  update_config {
    max_unavailable = 1
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.system_node,
    aws_eks_addon.before_nodes,
    aws_eks_addon.vpc_cni,
  ]
}

resource "aws_eks_addon" "after_nodes" {
  for_each = toset(local.addons_after_nodes)

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.value
  # var.test_invalid_coredns_version is test-only (null outside tests).
  addon_version = (
    each.value == "coredns" && var.test_invalid_coredns_version != null
    ? var.test_invalid_coredns_version
    : local.addon_versions[var.kubernetes_version][each.value]
  )
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system]
}
