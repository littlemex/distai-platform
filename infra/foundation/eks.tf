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

  upgrade_policy {
    support_type = "STANDARD"
  }

  lifecycle {
    precondition {
      condition     = contains(keys(local.addon_versions), var.kubernetes_version)
      error_message = "No pinned add-on versions for this kubernetes_version; add an entry to local.addon_versions in eks.tf."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
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
  node_managed_policies = [
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore",
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

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = local.addon_versions[var.kubernetes_version][each.value]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system]
}
