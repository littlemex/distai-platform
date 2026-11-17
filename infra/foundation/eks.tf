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
  # nodes become Ready; CoreDNS (a Deployment) is installed after it.
  addons_before_nodes = ["vpc-cni", "kube-proxy", "eks-pod-identity-agent"]
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
  node_managed_policies = [
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
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

resource "aws_eks_addon" "before_nodes" {
  for_each = toset(local.addons_before_nodes)

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = local.addon_versions[var.kubernetes_version][each.value]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.system_node.arn
  subnet_ids      = local.cluster_subnet_ids
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = var.system_node_group.instance_types

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
