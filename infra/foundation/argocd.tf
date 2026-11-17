# Optional EKS managed Argo CD capability, created only when var.argocd is set
# (hub cells). Users sign in through IAM Identity Center; the groups in
# var.argocd.admin_group_ids get the Argo CD ADMIN role.

data "aws_iam_policy_document" "argocd_assume" {
  count = var.argocd == null ? 0 : 1

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

      rbac_role_mapping {
        role = "ADMIN"

        dynamic "identity" {
          for_each = toset(var.argocd.admin_group_ids)

          content {
            id   = identity.value
            type = "SSO_GROUP"
          }
        }
      }
    }
  }
}
