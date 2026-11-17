# AWS-side prerequisites of Karpenter v1.15, following the reference
# CloudFormation template of the Karpenter documentation
# (website/content/en/v1.15/getting-started/getting-started-with-karpenter/cloudformation.yaml
# in aws/karpenter-provider-aws). Karpenter itself is installed by Argo CD.

locals {
  karpenter_namespace       = "kube-system"
  karpenter_service_account = "karpenter"

  region_prefix = "arn:${local.partition}:ec2:${var.region}"

  karpenter_interruption_events = {
    "scheduled-change" = {
      source      = "aws.health"
      detail_type = "AWS Health Event"
    }
    "spot-interruption" = {
      source      = "aws.ec2"
      detail_type = "EC2 Spot Instance Interruption Warning"
    }
    "rebalance" = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance Rebalance Recommendation"
    }
    "instance-state-change" = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance State-change Notification"
    }
    "capacity-reservation" = {
      source      = "aws.ec2"
      detail_type = "EC2 Capacity Reservation Instance Interruption Warning"
    }
  }
}

# --- Node role ---------------------------------------------------------------

resource "aws_iam_role" "karpenter_node" {
  name               = "${var.name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset(local.node_managed_policies)

  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# --- Interruption queue ------------------------------------------------------

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = var.name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_cloudwatch_event_rule" "karpenter_interruption" {
  for_each = local.karpenter_interruption_events

  name        = "${var.name}-karpenter-${each.key}"
  description = "Karpenter interruption handling for cluster ${var.name}: ${each.value.detail_type}"

  event_pattern = jsonencode({
    source        = [each.value.source]
    "detail-type" = [each.value.detail_type]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_interruption" {
  for_each = aws_cloudwatch_event_rule.karpenter_interruption

  rule      = each.value.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

data "aws_iam_policy_document" "karpenter_interruption_queue" {
  statement {
    sid       = "AllowEventBridgeRules"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter_interruption.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for r in aws_cloudwatch_event_rule.karpenter_interruption : r.arn]
    }
  }

  statement {
    sid       = "DenyHTTP"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.karpenter_interruption.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy    = data.aws_iam_policy_document.karpenter_interruption_queue.json
}

# --- Controller role (EKS Pod Identity) --------------------------------------

data "aws_iam_policy_document" "karpenter_controller_assume" {
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

    # EKS Pod Identity sets these session tags; only the Karpenter service
    # account of this cluster can assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [local.cluster_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.karpenter_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.karpenter_service_account]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume.json
}

data "aws_iam_policy_document" "karpenter_node_lifecycle" {
  statement {
    sid = "AllowScopedEC2InstanceAccessActions"
    resources = [
      "${local.region_prefix}::image/*",
      "${local.region_prefix}::snapshot/*",
      "${local.region_prefix}:*:security-group/*",
      "${local.region_prefix}:*:subnet/*",
      "${local.region_prefix}:*:capacity-reservation/*",
      "${local.region_prefix}:*:placement-group/*",
    ]
    actions = ["ec2:RunInstances", "ec2:CreateFleet"]
  }

  statement {
    sid       = "AllowScopedEC2LaunchTemplateAccessActions"
    resources = ["${local.region_prefix}:*:launch-template/*"]
    actions   = ["ec2:RunInstances", "ec2:CreateFleet"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid = "AllowScopedEC2InstanceActionsWithTags"
    resources = [
      "${local.region_prefix}:*:fleet/*",
      "${local.region_prefix}:*:instance/*",
      "${local.region_prefix}:*:volume/*",
      "${local.region_prefix}:*:network-interface/*",
      "${local.region_prefix}:*:launch-template/*",
      "${local.region_prefix}:*:spot-instances-request/*",
    ]
    actions = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.name]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid = "AllowScopedResourceCreationTagging"
    resources = [
      "${local.region_prefix}:*:fleet/*",
      "${local.region_prefix}:*:instance/*",
      "${local.region_prefix}:*:volume/*",
      "${local.region_prefix}:*:network-interface/*",
      "${local.region_prefix}:*:launch-template/*",
      "${local.region_prefix}:*:spot-instances-request/*",
    ]
    actions = ["ec2:CreateTags"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.name]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedResourceTagging"
    resources = ["${local.region_prefix}:*:instance/*"]
    actions   = ["ec2:CreateTags"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.name]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"]
    }
  }

  statement {
    sid = "AllowScopedDeletion"
    resources = [
      "${local.region_prefix}:*:instance/*",
      "${local.region_prefix}:*:launch-template/*",
    ]
    actions = ["ec2:TerminateInstances", "ec2:RebootInstances", "ec2:DeleteLaunchTemplate"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }
}

data "aws_iam_policy_document" "karpenter_iam_integration" {
  statement {
    sid       = "AllowPassingInstanceRole"
    resources = [aws_iam_role.karpenter_node.arn]
    actions   = ["iam:PassRole"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com", "ec2.amazonaws.com.cn"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileCreationActions"
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
    actions   = ["iam:CreateInstanceProfile"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [var.region]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileTagActions"
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
    actions   = ["iam:TagInstanceProfile"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [var.region]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [var.region]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileActions"
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [var.region]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }
}

data "aws_iam_policy_document" "karpenter_eks_integration" {
  statement {
    sid       = "AllowAPIServerEndpointDiscovery"
    resources = [local.cluster_arn]
    actions   = ["eks:DescribeCluster"]
  }
}

data "aws_iam_policy_document" "karpenter_interruption" {
  statement {
    sid       = "AllowInterruptionQueueActions"
    resources = [aws_sqs_queue.karpenter_interruption.arn]
    actions   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
  }
}

data "aws_iam_policy_document" "karpenter_zonal_shift" {
  statement {
    sid       = "AllowZonalShiftStatusReadOnly"
    resources = ["*"]
    actions   = ["arc-zonal-shift:GetManagedResource"]

    condition {
      test     = "StringEquals"
      variable = "arc-zonal-shift:ResourceIdentifier"
      values   = [local.cluster_arn]
    }
  }
}

data "aws_iam_policy_document" "karpenter_resource_discovery" {
  statement {
    sid       = "AllowRegionalReadActions"
    resources = ["*"]
    actions = [
      "ec2:DescribeCapacityReservations",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribePlacementGroups",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "AllowSSMReadActions"
    resources = ["arn:${local.partition}:ssm:${var.region}::parameter/aws/service/*"]
    actions   = ["ssm:GetParameter"]
  }

  statement {
    sid       = "AllowPricingReadActions"
    resources = ["*"]
    actions   = ["pricing:GetProducts"]
  }

  statement {
    sid       = "AllowUnscopedInstanceProfileListAction"
    resources = ["*"]
    actions   = ["iam:ListInstanceProfiles"]
  }

  statement {
    sid       = "AllowInstanceProfileReadActions"
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
    actions   = ["iam:GetInstanceProfile"]
  }
}

locals {
  karpenter_controller_policies = {
    "node-lifecycle"     = data.aws_iam_policy_document.karpenter_node_lifecycle.json
    "iam-integration"    = data.aws_iam_policy_document.karpenter_iam_integration.json
    "eks-integration"    = data.aws_iam_policy_document.karpenter_eks_integration.json
    "interruption"       = data.aws_iam_policy_document.karpenter_interruption.json
    "zonal-shift"        = data.aws_iam_policy_document.karpenter_zonal_shift.json
    "resource-discovery" = data.aws_iam_policy_document.karpenter_resource_discovery.json
  }
}

resource "aws_iam_policy" "karpenter_controller" {
  for_each = local.karpenter_controller_policies

  name        = "${var.name}-karpenter-${each.key}"
  description = "Karpenter controller permissions (${each.key}) for cluster ${var.name}"
  policy      = each.value
}

# The attachments depend on the teardown guard so that on destroy they are
# removed first: once the controller role has no permissions, a running
# Karpenter cannot launch replacement instances while the guard terminates the
# existing ones (see teardown.tf).
resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  for_each = aws_iam_policy.karpenter_controller

  role       = aws_iam_role.karpenter_controller.name
  policy_arn = each.value.arn

  depends_on = [terraform_data.teardown_guard]
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = local.karpenter_namespace
  service_account = local.karpenter_service_account
  role_arn        = aws_iam_role.karpenter_controller.arn

  depends_on = [aws_eks_addon.before_nodes]
}
