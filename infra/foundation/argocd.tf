# Optional EKS managed Argo CD capability, created only when var.argocd is set
# (hub cells). Users sign in through IAM Identity Center; each entry of
# var.argocd.role_mappings gives its Identity Center groups one Argo CD role
# (ADMIN, EDITOR or VIEWER). Per-team AppProjects, which turn that role into
# access to one team's applications rather than all of them, are the tenancy
# layer's.

data "aws_iam_policy_document" "argocd_assume" {
  count = var.argocd == null ? 0 : 1

  # No aws:SourceAccount/aws:SourceArn condition here, unlike this layer's
  # own Pod Identity trust policies (eks.tf, karpenter.tf) -- checked, not
  # overlooked (#63, filed as a private report "SA1" item 5/3). Every
  # published AWS example of this exact trust policy
  # (docs.aws.amazon.com/eks/latest/userguide/argocd-register-clusters.html,
  # the EKS managed Argo CD capability's own setup docs) has no Condition
  # block, and nothing in AWS's own documentation says the
  # capabilities.eks.amazonaws.com service principal passes either context
  # key on this AssumeRole call. Adding an unconfirmed condition to the
  # most privileged role in this stack risks the opposite of a narrowing:
  # a failed AssumeRole breaks the capability (and, through it, every
  # cell's own GitOps delivery) outright, not a confused-deputy path that
  # is otherwise undemonstrated (SA1 item 5 already notes exploiting this
  # gap needs iam:PassRole on this role, which nothing in this repository
  # grants). This is a researched decision not to add the condition, not
  # an unaddressed item.
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["capabilities.eks.amazonaws.com"]
    }
  }
}

# No permission policies are attached: the capability reaches its own cluster
# through the access entry that EKS creates for it. Grant access to
# repositories or secrets in a later layer when a hub needs them.
resource "aws_iam_role" "argocd" {
  count = var.argocd == null ? 0 : 1

  name               = "${var.name}-argocd-capability"
  assume_role_policy = data.aws_iam_policy_document.argocd_assume[0].json
}

resource "aws_eks_capability" "argocd" {
  count = var.argocd == null ? 0 : 1

  cluster_name              = aws_eks_cluster.this.name
  capability_name           = "argocd"
  type                      = "ARGOCD"
  role_arn                  = aws_iam_role.argocd[0].arn
  delete_propagation_policy = "RETAIN"

  configuration {
    argo_cd {
      aws_idc {
        idc_instance_arn = var.argocd.idc_instance_arn
        idc_region       = var.argocd.idc_region
      }

      dynamic "rbac_role_mapping" {
        for_each = { for m in var.argocd.role_mappings : m.role => m }

        content {
          role = rbac_role_mapping.value.role

          dynamic "identity" {
            for_each = toset(rbac_role_mapping.value.group_ids)

            content {
              id   = identity.value
              type = "SSO_GROUP"
            }
          }
        }
      }
    }
  }
}
